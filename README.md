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

The plugin ships a **generic starter Dockerfile** (`default.Dockerfile`): the stock
self-hosted runner base plus a docker-in-docker readiness wrapper. Customize it from the UI's
**Runner image builder** (add language runtimes, browsers, build tools), Build, and the fleet
uses the resulting tag (the `IMAGE` setting).

Keep heavier or organization-specific image recipes in your own repository and point `IMAGE` at
the image you build there.

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
