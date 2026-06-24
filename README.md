# CI Runner Farm — Unraid plugin

Manage a fleet of **GitHub Actions self-hosted runners as Docker containers** on Unraid —
multiple concurrent, resource-capped runners with warm shared caches, with no VM required.

## What it does

- Runs **N concurrent runners**, each a container, optionally capped with `--cpus` / `--memory`
  so builds coexist with the host.
- **Queue-aware autoscaling**: an optional daemon floats the fleet between a min and max by demand.
- **Warm shared caches** on a fast pool, reused across runs.
- **Docker-in-Docker** per runner (default) so jobs using `services:` / `docker compose` work,
  with an optional shared pull-through registry mirror so images are pulled once.
- Bring-your-own **runner image**: point the `IMAGE` setting at any image you build (see below).
- Web UI under **Settings → Utilities → CI Runner Farm**: configure, set the PAT,
  Start/Stop/Restart/Scale, live status, and an in-plugin image builder.

## Install

```
plugin install /path/to/ci-runner-farm.plg      # or via Plugins > Install Plugin (URL/file)
```

Rebuild the `.plg` after edits with `./build-plg.sh`.

## Configure

1. **Settings → Utilities → CI Runner Farm**.
2. Fill in scope (`repo` or `org`), runner count, optional CPU/mem caps, labels, and cache root.
3. **Save token**: a GitHub PAT (repo scope; add `admin:org` for org runners). Stored at
   `/boot/config/plugins/ci-runner-farm/token`, chmod 600 — never in `config.cfg`.
4. **Validate** (no token needed) to prove provisioning on this host, then **Start**.

## Runner image

**Image source** (UI select) picks where the runner image comes from:

- **Built-in** (default) — run the image you build with the in-plugin **Runner image builder**,
  tagged `ci-runner-farm-runner:latest`. The plugin ships a generic starter `default.Dockerfile`
  (stock runner base + a docker-in-docker readiness wrapper); customize it (add language runtimes,
  browsers, build tools), Build, and restart. No registry needed.
- **Remote** — pull the image named in **Remote image** (`IMAGE`) from a registry, e.g.
  `ghcr.io/org/ci-runner-image:latest`. Keep heavier or org-specific recipes in their own repo and
  point here. For a **private** image, set the registry server + username and save a registry token;
  the host runs `docker login` before provisioning. For `ghcr.io`, leaving the registry token blank
  reuses the GitHub PAT (it must have `read:packages`).

The warm caches mounted into every runner are configurable via `CACHE_MOUNTS`
(`host-subdir:container-path`, space-separated); defaults cover pnpm/npm/yarn/Playwright.

## CLI

```
include/runner-farm.sh {start|boot-autostart|stop|restart|scale N|status|status-json|logs i|validate|build-image|prune-cache|autoscale-*}
```

## Security notes

- Docker-in-DinD runners are `--privileged`; the shared-socket mode gives runners
  root-equivalent host access. Use self-hosted runners **only for trusted/private repositories** —
  fork-PR code from public repos must never run on a privileged or socket-mounted self-hosted runner.
- For stronger isolation, set `EPHEMERAL=true` (a clean runner per job).

## Layout

```
ci-runner-farm.plg                 self-contained installer (built)
build-plg.sh                       packages src/ -> .plg
src/usr/local/emhttp/plugins/ci-runner-farm/
  RunnerFarm.page                  Settings page (Dynamix)
  default.cfg                      seed config
  default.Dockerfile               generic starter runner image
  include/runner-farm.sh           provisioning/control script
  include/exec.php                 CSRF-guarded web endpoint
```
