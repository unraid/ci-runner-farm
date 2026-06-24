# CI Runner Farm for Unraid

Turn your Unraid server into a fleet of **GitHub Actions self-hosted runners** —
multiple concurrent, resource-capped runners running as Docker containers, with
warm shared caches and **no VM required**. Point it at a repo or org, paste a
token, and your builds run on your own hardware.

> **Why?** Hosted CI minutes are slow and metered. An Unraid box with spare
> cores and a fast cache pool can run many builds in parallel, keep dependency
> caches hot between runs, and cost nothing per minute.

---

## Features

- **N concurrent runners**, each its own container, optionally capped with
  `--cpus` / `--memory` so CI never starves the rest of the host.
- **Queue-aware autoscaling** — an optional daemon floats the fleet between a
  min and max based on how many jobs are waiting.
- **Warm shared caches** on a fast pool (pnpm/npm/yarn/Playwright by default,
  fully configurable), reused across every run.
- **Docker-in-Docker per runner** so jobs using `services:` or
  `docker compose` just work — with an optional shared pull-through registry
  mirror so images are pulled once for the whole fleet.
- **Bring your own runner image** — use the in-plugin image builder or point at
  any image you publish to a registry (public or private).
- **Web UI** under **Settings → Utilities → CI Runner Farm**: configure
  everything, store the token securely, Start/Stop/Restart/Scale, watch live
  status, and build your runner image — no shell required.

---

## Install

### Community Applications (recommended)

Search for **CI Runner Farm** in [Community Applications](https://unraid.net/community/apps)
and click **Install**.

### Install by URL

In the Unraid webGUI go to **Plugins → Install Plugin** and paste:

```
https://github.com/unraid/ci-runner-farm/releases/latest/download/ci-runner-farm.plg
```

Unraid always resolves this to the newest published release, and its built-in
"check for updates" keeps the plugin current.

---

## Quick start

1. Open **Settings → Utilities → CI Runner Farm**.
2. Set the **scope** (`repo` or `org`), the **runner count**, optional CPU/mem
   caps, labels, and the cache root.
3. **Save token** — a GitHub PAT (`repo` scope; add `admin:org` for org
   runners). It's stored at `/boot/config/plugins/ci-runner-farm/token`,
   `chmod 600`, and never written into `config.cfg`.
4. Click **Validate** (no token needed) to confirm the host can provision, then
   **Start**.

That's it — your runners register with GitHub and start picking up jobs.

---

## Runner image

The **Image source** selector decides where each runner's image comes from:

- **Built-in** (default) — run the image built by the in-plugin
  **Runner image builder**, tagged `ci-runner-farm-runner:latest`. The plugin
  ships a generic starter [`default.Dockerfile`](src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile)
  (stock runner base + a docker-in-docker readiness wrapper). Customize it — add
  language runtimes, browsers, build tools — then **Build** and restart. No
  registry needed.
- **Remote** — pull the image named in **Remote image** (`IMAGE`), e.g.
  `ghcr.io/org/ci-runner-image:latest`. For a **private** image, set the
  registry server + username and save a registry token; the host runs
  `docker login` before provisioning. For `ghcr.io`, leaving the registry token
  blank reuses the GitHub PAT (it must have `read:packages`).

The warm caches mounted into every runner are configurable via `CACHE_MOUNTS`
(`host-subdir:container-path`, space-separated); the defaults cover
pnpm/npm/yarn/Playwright.

---

## Security

Self-hosted runners execute arbitrary workflow code on your hardware. Read this
before exposing the fleet:

- DinD runners run `--privileged`, and the shared-socket mode gives runners
  root-equivalent access to the host. Use self-hosted runners **only for
  trusted/private repositories**. Fork-PR code from public repos must **never**
  run on a privileged or socket-mounted self-hosted runner.
- For stronger isolation, set `EPHEMERAL=true` so each job gets a clean runner.

See GitHub's [self-hosted runner security guidance](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#self-hosted-runner-security)
for the full picture.

---

## CLI

Everything in the UI maps to the control script:

```
include/runner-farm.sh {start|boot-autostart|stop|restart|scale N|status|status-json|logs i|validate|build-image|prune-cache|autoscale-*}
```

---

## Releases & versioning

Releases are automated with
[release-please](https://github.com/googleapis/release-please) and published as
**GitHub Release assets** — the same flow used by Unraid's other plugins.

- `.release-please-manifest.json` is the SemVer source of truth; `VERSION`
  mirrors it for tooling.
- Merging [Conventional Commits](https://www.conventionalcommits.org) to `main`
  opens a release PR. That PR regenerates the self-contained
  `ci-runner-farm.plg` (version entities + embedded payload) and updates
  `CHANGELOG.md`.
- Merging the release PR tags `vX.Y.Z`, cuts a GitHub Release, validates the
  tagged `.plg`, and uploads it as the `ci-runner-farm.plg` release asset that
  the install URL above resolves to.

The Unraid plugin-manager `<version>` is written as
`YYYY.MM.DD.HHMM.BUILD-INTERNAL` (e.g. `2026.06.24.1530.42-0.1.0`) so it sorts
chronologically in the plugin manager while still pinning the SemVer release.

---

## Development

```sh
./build-plg.sh                 # build ci-runner-farm.plg from src/ (date-stamped dev build)
./deploy.sh root@tower         # rsync src/ to a dev Unraid host (fast iteration; not for installs)
```

The `.plg` is fully self-contained: the plugin file tree is tarred,
base64-encoded, and embedded inline, so installing only ever fetches the single
`.plg` — no external file hosting.

### Layout

```
ci-runner-farm.plg                 self-contained installer (built artifact, committed)
build-plg.sh                       packages src/ -> versioned .plg
deploy.sh                          dev-only raw deploy to an Unraid host
release-please-config.json         release-please configuration
.release-please-manifest.json      SemVer source of truth
VERSION                            mirror of the internal SemVer version
src/usr/local/emhttp/plugins/ci-runner-farm/
  RunnerFarm.page                  Settings page (Dynamix)
  default.cfg                      seed config
  default.Dockerfile               generic starter runner image
  include/runner-farm.sh           provisioning/control script
  include/exec.php                 CSRF-guarded web endpoint
.github/workflows/
  package-plugins.yml              PR/branch build + validate
  release-please.yml               release automation + asset upload
  release.yml                      tagged-release validation
```

---

## Support

Questions and bug reports: <https://github.com/unraid/ci-runner-farm/issues>
