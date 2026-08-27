# Share build caches through an existing registry

The optional **Build cache profile** lets CI jobs reuse exported Docker build
layers across runners. Each slot keeps its own Docker daemon and writable data.
The plugin supplies configuration, not a registry server or registry credentials.
The existing pull-through image mirror remains separate and cannot accept cache
exports.

## Configure the farm

1. Open **Settings → CI Runner Farm → Settings → Build cache profile**.
2. Select **Existing registry (workflow opt-in)**.
3. Enter a tagless repository, such as `registry.example.com/team/build-cache`.
4. Set **Local cache budget per builder (GiB)**. The default is 20 GiB.
5. Apply the settings. In classic mode, wait for runners to finish their jobs and adopt the new profile.
6. For named pools, schedule a **Fleet Restart** after active jobs finish. Apply alone does not replace those runners.
7. Wait for the replacement runners before updating build workflows as described below.

The configuration keys are `BUILD_CACHE_MODE` (`off` or `registry`),
`BUILD_CACHE_REPOSITORY`, and `BUILD_CACHE_LOCAL_GIB` (1–1024).
Off preserves existing behavior, including runner configuration fingerprints.
Registry mode requires Docker-in-Docker. Host-socket mode is not supported.

Each GitHub runner and GitLab Docker-executor job receives two read-only files:

- `/etc/ci-runner-farm/build-cache/profile.env`: the repository and config path.
- `/etc/ci-runner-farm/build-cache/buildkitd.toml`: the OCI worker's GC budget.

Profiles are immutable snapshots. Changes do not rewrite files mounted by busy
jobs. Old snapshots remain in the plugin's runtime directory until reboot.
The current snapshot is generated again during runner provisioning.

## Use the profile in a workflow

Use a current Buildx client and BuildKit version that supports `maxUsedSpace`.
This profile targets the OCI worker in a `docker-container` builder. It does not
configure arbitrary existing builders, remote builders, or `docker build` calls.
GitLab job images must include the Docker CLI and Buildx plugin.

Authenticate to the cache registry inside the job, using a credential with only
the required repository permissions. The plugin does not expose its host PAT,
runner token, or image-pull credentials through this profile. Configure private
CA trust in the job/builder when required. The profile does not disable TLS or
relax the farm's network firewall. A registry blocked by strict isolation remains
blocked.

This shell example works in a GitHub shell job or GitLab job. Set
`CACHE_SCOPE` from a stable hash of the full project, build target, platform, and
branch identity. Use the same scope on different runners to reuse their cache.
Keep output image references separate from cache references.

```bash
set -euo pipefail
. /etc/ci-runner-farm/build-cache/profile.env
: "${CACHE_SCOPE:?Set a project/target/platform/branch-specific cache scope}"
[[ "$CACHE_SCOPE" =~ ^[a-z0-9][a-z0-9_.-]{0,100}$ ]] || exit 1
cache_ref="${CRF_BUILD_CACHE_REPOSITORY}:${CACHE_SCOPE}"
builder="crf-$(cat /proc/sys/kernel/random/uuid)"
docker buildx create --name "$builder" --driver docker-container \
  --buildkitd-config "$CRF_BUILDKIT_CONFIG" --bootstrap
trap 'docker buildx rm "$builder"' EXIT
docker buildx build --builder "$builder" \
  --cache-from "type=registry,ref=$cache_ref" \
  --cache-to "type=registry,ref=$cache_ref,mode=max,image-manifest=true" \
  --load -t example/app:ci .
```

The example removes only its own builder after the job. Registry cache survives
that cleanup. A workflow may retain its own builder instead, but it must recreate
that builder when the profile changes so the new GC budget takes effect.
GitHub jobs using `container:` must also mount the profile directory read-only
into their job container. Shell jobs receive it directly.

For GitHub's Docker actions, load `profile.env` in a shell step and write the
needed values to `$GITHUB_OUTPUT`. Pass the config path to
`docker/setup-buildx-action` as `buildkitd-config`. Pass explicitly scoped refs to
`docker/build-push-action` as `cache-from` and `cache-to`. Do not assume that the
runner's environment automatically appears in GitHub's expression `env` context.
See Docker's [builder configuration](https://docs.docker.com/build/ci/github-actions/configure-builder/)
and [registry cache examples](https://docs.docker.com/build/ci/github-actions/cache/).

## Scope, failure, and storage limits

Cache names are not an access-control boundary. Only trusted jobs should share
a writable cache repository. Separate projects and trust levels with registry
permissions and separate repositories. Never give untrusted pull requests a
credential that can overwrite trusted caches. Branch-specific tags avoid normal
collisions but do not stop a credential holder from choosing another tag.
Serialize exports to the same ref, or use separate refs for concurrent writers.
Use BuildKit secret mounts for secrets; never bake credentials into layers.

The profile provides no implicit `latest` cache tag. A missing import cache is a
normal cold build under Docker's behavior. Export failures remain job failures
unless the workflow deliberately changes Docker's default error handling. Do not
add `ignore-error=true` or fall back to an unconfigured builder to hide failures.

The local budget is a garbage-collection target, not a hard quota. Active build
data can exceed it. It does not cover Docker images, other builders, workspaces,
package caches, or the image mirror. Exported caches also need registry retention
and garbage collection, controlled by the registry owner. Reducing local budgets
trades disk use for cache downloads and depends on registry availability.

Enabling this option does not prune old builders or immediately recover their
disk space. Migrate workflows first, then retire unused builders through their
normal owner. Remove workflow references to the profile before disabling the
option. Classic fleets remove the mount as runners drain and are replaced.
Named pools require the same scheduled Fleet Restart described above.

## Keep caches across Stop and Restart

**Stop** and **Restart** retain per-slot Docker data, GitLab job caches, and the
shared image mirror cache. A later Start reuses the retained data for the same
slot and cache root. This applies with the build cache profile on or off.
The plugin still removes runner containers and performs provider credential
cleanup. Plugin uninstall and active GitLab runner-token removal also retain
caches because they use Stop.

Stop does not guarantee that active jobs finish. Schedule maintenance before
using Stop or Restart. Manual scale-down, autoscale-down, and permanent slot
retirement still delete that slot's Docker data and GitLab job cache. Registry
exports are unaffected.

To delete retained local caches, stop the fleet, then run the explicit command:

```bash
/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh prune-cache
```

This command deletes plugin-owned cache directories under the configured cache
root. It refuses to proceed while managed runners, sidecars, or job containers
remain. Cache retention does not reduce existing disk use.

## Verification

`bash tests/build-cache.sh` checks profile validation, snapshots, fingerprints,
and both providers' mount contracts without external services.
`bash tests/cache-retention.sh` checks Stop/Restart retention and explicit cache
deletion for both providers using disposable on-disk fixtures.
`bash tests/build-cache-integration.sh` uses disposable local Docker builders and
a test registry to prove cross-builder cache reuse and effective GC settings.
It does not contact a farm host or modify existing runners.

### Verify an authenticated registry

The **Lint** workflow has a manual **Also verify authenticated GHCR cache reuse**
option. Run it only from a trusted, reviewed ref. Pull-request events cannot
start this package-writing job. GitHub assigns its runner.

The job uses its short-lived `GITHUB_TOKEN` with `packages: write`, not a farm
credential. It exports synthetic Busybox layers to
`ghcr.io/<owner>/<repository>-build-cache:proof-<run-id>-<attempt>`.
Two fresh builders must have different local volumes, and the second must reuse
the exported `RUN` layer. Authentication or export errors fail the test.
The test never substitutes a local registry when the external registry fails.

New GHCR packages are private by default. After the first run, verify that the
package remains private and is linked to the workflow repository. Keep package
access limited to authorized workflows. The job removes its temporary Docker
credentials and local test resources. It leaves the small proof tag for
inspection; the package owner controls retention.

For another registry, authenticate through a temporary, job-owned Docker config.
Set `CRF_CACHE_TEST_REPOSITORY` to its tagless repository and
`CRF_CACHE_TEST_TAG` to a unique tag starting with `proof-`. Then run
`bash tests/build-cache-integration.sh`. Both inputs are required together.
Do not use the farm's host PAT, runner token, or image-pull credential.

This check uses the plugin's generated profile in an isolated fixture. It does
not prove that a deployed runner has adopted its profile or that a production
workflow uses it. Verify the deployed read-only mount separately, then configure
each authorized build workflow as described above. Enabling the farm option
alone does not change existing build commands or reduce their old cache data.

On macOS, use `bash tests/run-linux-checks.sh` with Docker running and Homebrew
Coreutils installed (`brew install coreutils`). The wrapper runs the shell suite
in Linux. Its real-Docker integration stage uses the installed GNU tools on the
host because the production snapshot generator requires GNU `mv -T`.
