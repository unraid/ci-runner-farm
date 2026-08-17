**CI Runner Farm**

Self-hosted GitHub Actions or GitLab CI/CD runners for Unraid, with concurrent
resource-capped slots, warm package/image caches, Docker-in-Docker, and optional
autoscaling. One provider owns the farm at a time; GitHub remains the default so
existing installations keep their behavior.

Named pools work with both providers. Each pool can use its own fixed capacity,
labels or tags, CPU, memory, and runner/job image. GitHub pools require
organization scope. GitLab pools require a pool-specific `glrt-` runner token
whose GitLab runner configuration owns the matching tags. Pool edits take
effect on Fleet Restart, so Settings Apply does not interrupt active jobs.

GitHub runner containers resolve `host.docker.internal` to their own Unraid
farm host. A colocated service can use this stable local address without a
machine-specific hostname. Strict network isolation still blocks host access.

For GitLab, create the runner and its tags/protection/scope in GitLab, then save
the reusable `glrt-` runner authentication token in the plugin. A separate
`read_api` token is optional and is used only for advisory queue/recent-job
statistics for configured monitored projects. A project access token covers only
one project; use a suitably scoped group token or dedicated PAT when monitoring
several projects. GitLab.com and self-managed HTTPS instances are supported,
including an uploaded custom PEM CA.

Paste only the raw runner-token value, not GitLab's `gitlab-runner register`
command, a flag, or surrounding quotes. GitLab 18.0 and later can issue routable
runner tokens whose opaque payload contains periods; those are supported.

The shared-token fleet accepts only modern manager tokens beginning exactly
`glrt-`, not registration-created `glrtr-` or instance-prefixed token variants.
Current official Runner releases select manager-only unregister by that exact
prefix; accepting another shape could delete the shared runner entity.
Retiring a slot uses its persisted system ID and saved manager name to remove only
that manager record; the shared runner entity and the other slots remain intact.

GitLab uses the official `gitlab/gitlab-runner` manager with the Docker executor.
The editable GitLab Dockerfile builds the default **job image**, not a modified
Runner manager. Leave DinD enabled for a private per-slot daemon, or explicitly
choose host-socket sharing only for trusted jobs; host Docker socket access is
root-equivalent. Host-socket Start and Validate require an official Runner image
reporting version 18.5.0 or newer, where exact build/helper/service slot labels
are reliable; DinD requires Runner 16.0.0 or newer for manager-only unregister
with system IDs. A GitLab
job, helper, or service container can control its slot's DinD socket and sibling
helper/service containers, and the DinD sidecar itself runs privileged; the
slot boundary prevents accidental cross-slot Docker access but is not a security
boundary against the Unraid host. Because every executor container receives that
Docker socket, its code can also pull/run images outside Runner's allowlists and request
privileged containers inside DinD. Image/service allowlists and locked pull
policies are admission guardrails, not a sandbox for untrusted pipelines.

GitLab job containers are always ephemeral even though managers and configured
caches persist. Native `/cache` data is disjoint per slot; custom cache mounts
are shared across slots and should be used only with concurrency-safe tools.
Optional image/service wildcard allowlists restrict `.gitlab-ci.yml` overrides;
blank allowlists preserve GitLab Runner's permissive default. Pull policy is
locked against job overrides, and job shared-memory size is configurable in
bytes. GitLab maximum job duration remains configured on the runner in GitLab,
not in the local manager TOML.

Autoscaling is off by default. When explicitly enabled for GitLab, scale demand
comes only from live manager metrics and observed job containers; advisory queue
telemetry for monitored projects is never used to drive capacity.

Credentials are stored separately under
`/boot/config/plugins/ci-runner-farm/` and never in the main configuration:
`token` (GitHub), `gitlab-runner-token`, optional `gitlab-api-token`, optional
`gitlab-ca.crt`, and optional `registry-token`. GitLab Runner necessarily copies
the reusable runner token into each mode-`0600`
`gitlab-runners/ci-runner-N/config.toml`. A successful slot retirement removes
that TOML, derived Docker auth, CA snapshot, and unregister marker while
preserving its system ID; any lifecycle failure keeps all retry material.
Clearing the active token applies the same cleanup across the fleet. The
plugin registers no diagnostics collector for these token-bearing files or the
derived Docker auth files; current Unraid diagnostics list the configuration
directory but do not copy their contents. They must not be attached manually to
support requests.

If GitLab is permanently unreachable or the manager token is revoked, normal
cleanup fails closed. The warning action on a GitLab Fleet row is a separately
confirmed local-only escape hatch: it interrupts that slot and removes its local
manager, jobs, privileged sidecar, token-bearing config, and slot Docker/cache
roots without contacting
GitLab. It can leave an offline manager record that must be removed in GitLab.

GitLab manager Stop/Restart/replacement sends `SIGQUIT`, stops accepting new
jobs, and waits up to `GITLAB_SHUTDOWN_TIMEOUT` (7200 seconds by default) for an
in-flight job before Docker forces shutdown. Before an Unraid array stop or
Docker-service restart, the `stopping_docker` hook quiesces every GitLab manager
in parallel while its DinD sidecar is still available. Provider changes use the same
idle-drained slot replacement, so a busy old-provider slot finishes and
deregisters before its new-provider replacement starts.

The uploaded CA is snapshotted per manager so an old manager can still
unregister during a trust-root rotation. It is used for manager API traffic and
mounted at GitLab Runner's standard helper trust path. Jobs receive the CA file but arbitrary job images
must install or explicitly use it themselves. In DinD mode it is also installed
for the configured private-registry authority. Registry auth and strict-network
access remain available in GitLab mode when a locally built default is overridden
by a job or service. Host-socket mode instead depends on the Unraid Docker
daemon's own registry trust configuration. GitLab registry endpoints must use
HTTPS; plain HTTP is rejected rather than transmitting registry credentials
through an insecure DinD registry.

The private daemon creates per-build networks from Docker's default address
pools. A self-managed GitLab or registry CIDR that overlaps those pools can be
shadowed by an inner Docker route; keep those endpoints on non-overlapping
subnets or configure suitable Docker default address pools for the deployment.
