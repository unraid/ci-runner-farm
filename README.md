# CI Runner Farm — Unraid plugin

Manages a fleet of **GitHub Actions self-hosted *build* runners as Docker containers** on Unraid.
Designed for the the host double-duty plan: lightweight, resource-capped build runners that
run **alongside** the existing `another-workload` (the destructive integration workload),
never touching it.

## What it does

- Runs **N concurrent runners**, each a container (no VM), capped with `--cpus` / `--memory`
  so multiple builds — and the host, and the other workloads — coexist on the 28-thread a multi-core host.
- **Warm shared caches** on the fast `fast_pool` (pnpm store, npm, yarn). Docker layer cache
  is shared host-wide for free via the mounted `docker.sock`.
- **Per-job workspace on tmpfs** (RAM-backed) → clean workspace each job, fast I/O, while caches stay warm.
- **Service-container support**: the host `docker.sock` is mounted, so jobs that run
  `docker compose up postgres` (e.g. account's integration tests: `postgres` + db-proxy)
  work as sibling containers.
- Web UI under **Settings → Utilities → CI Runner Farm**: configure, set the PAT, Start/Stop/
  Restart/Scale, live status table.

## Install

```
plugin install /path/to/ci-runner-farm.plg      # or via Plugins > Install Plugin (URL/file)
```
The `.plg` is self-contained (base64 payload) — no external hosting required.
Rebuild after edits with `./build-plg.sh`.

## Configure

1. **Settings → Utilities → CI Runner Farm**.
2. Fill in scope (`repo` for `unraid/repo-a unraid/repo-b`, or `org`), runner count, CPU/mem caps,
   labels, cache root.
3. **Save token**: a GitHub PAT (repo scope; add `admin:org` for org runners). Stored at
   `/boot/config/plugins/ci-runner-farm/token`, chmod 600 — never in `config.cfg`.
4. **Validate** (no token needed) to prove provisioning on this host, then **Start**.

## CLI

```
include/runner-farm.sh {start|stop|restart|scale N|status|status-json|logs i|validate|prune-cache}
```

## Security notes

- Mounting `docker.sock` gives runners root-equivalent host access. Use **only for private repos**
  (`account`, `connect`). **Keep public `unraid/api` on GitHub-hosted** — fork-PR code must never
  run on a socket-mounted self-hosted runner.
- For stronger isolation later, set `EPHEMERAL=true` (clean runner per job) and/or switch to
  rootless Docker-in-Docker instead of the shared socket.

## Layout

```
ci-runner-farm.plg                 self-contained installer (built)
build-plg.sh                       packages src/ -> .plg
src/usr/local/emhttp/plugins/ci-runner-farm/
  RunnerFarm.page                  Settings page (Dynamix)
  default.cfg                      seed config
  include/runner-farm.sh           provisioning/control script
  include/exec.php                 CSRF-guarded web endpoint
```

## Verified on the host (Unraid 7.3.1, a multi-core host, 125 GB)

- Provisioning mechanics: cpu/mem caps, SSD-pool cache mounts, docker.sock reachable, 8 GB tmpfs `/_work`.
- `exec.php`: valid CSRF passes, bad CSRF → 403.
- Full UI → endpoint → script chain (validate) green.
- Clean install via `plugin install`: files land, config seeds, script runs.
- **Not yet tested:** live runner registration + a real concurrent build — needs a GitHub PAT.
```
