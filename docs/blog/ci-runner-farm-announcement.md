# Turn your Unraid server into a GitHub Actions build farm

Hosted CI minutes are slow and metered. Meanwhile, the Unraid server in your
rack has spare cores and a fast cache pool sitting idle between media tasks.
**CI Runner Farm** puts them to work: it turns your server into a fleet of
**GitHub Actions self-hosted runners** — multiple concurrent, resource-capped
runners running as Docker containers, with warm shared caches, queue-aware
autoscaling, and Docker-in-Docker. No VM required.

Point it at a repo or organization, paste a token, and your builds run on your
own hardware — as many in parallel as your box can handle, with dependency
caches that stay hot between runs, at zero cost per minute.

---

## Why run your own CI?

- **Cost.** Hosted CI bills by the minute. A server you already own runs builds
  for the price of the electricity.
- **Speed.** Run many jobs in parallel and keep pnpm/npm/yarn/Playwright caches
  warm on a local NVMe pool — no re-downloading the world on every run.
- **It's the Unraid thing to do.** Self-hosted runners are just Docker
  containers, and Docker is what your server is already great at. This is "do
  more with the hardware you have," turned up to a build farm.
- **A couple of clicks to install.** It's a normal plugin from Community
  Applications, configured entirely from the webGUI.

---

## What you get

| Capability | What it means |
|---|---|
| **N concurrent runners** | Each runner is its own container, optionally capped with `--cpus` / `--memory` so CI never starves the rest of the host. |
| **Queue-aware autoscaling** | An optional daemon floats the fleet between a min and max based on how many jobs are waiting — capacity when you need it, idle when you don't. |
| **Warm shared caches** | pnpm / npm / yarn / Playwright caches (fully configurable) live on a fast pool and are reused across every run. This is the biggest hidden speed win over hosted CI. |
| **Docker-in-Docker per runner** | Jobs that use `services:` or `docker compose` just work, with an optional shared pull-through registry mirror so images are pulled once for the whole fleet. |
| **Bring your own image** | Use the in-plugin image builder, or point at any image you publish to a registry (public or private). |
| **One webGUI page** | Configure everything, store your token securely, Start/Stop/Restart/Scale, watch live status, and build your runner image — no shell required. |

---

## How it works

The plugin provisions a set of Docker containers from a runner image — built
in-plugin or pulled from a registry. Each container registers itself with GitHub
as a self-hosted runner, either at **repo** scope or **org** scope (org scope
gives you one shared pool that any of your private repos can pull from).

Persistent package caches and the build workspace are bind-mounted from a fast
pool so they survive across jobs. An optional companion container runs a
**pull-through registry mirror**, so Docker-in-Docker jobs across the whole fleet
pull each image only once. And an optional autoscaler watches the GitHub job
queue, scaling the fleet up toward your max when work is waiting and back down to
your min when things go quiet.

---

## Setup, step by step

You'll need an Unraid server, a GitHub Personal Access Token, and a fast
pool/share for caches. Install from **Community Applications** (search "CI Runner
Farm"), or by URL via **Plugins → Install Plugin**:

```
https://github.com/unraid/ci-runner-farm/releases/latest/download/ci-runner-farm.plg
```

### 1. Point it at GitHub and size the fleet

Open **Settings → Utilities → CI Runner Farm**. Choose your **scope** (`repo`
or `org`), set the **owner** and target repos, an optional **runner group**, and
how many **concurrent runners** to run. Add **runner labels** (so workflows can
target this fleet with `runs-on:`) and optional **CPU / memory caps per runner**
so CI can't starve the rest of the box.

![GitHub scope, target repos, runner count, labels, and per-runner CPU/memory caps](images/1-settings-github-runners.png)

### 2. Choose a runner image, caches, and Docker mode

The **Image source** selector decides where each runner's image comes from:

- **Built-in** (default) — run the image built by the in-plugin **Runner image
  builder**, tagged `ci-runner-farm-runner:latest`. The plugin ships a generic
  starter Dockerfile (stock runner base + a Docker-in-Docker readiness wrapper);
  customize it — add language runtimes, browsers, build tools — then **Build**
  and restart. No registry needed.
- **Remote** — pull a named image, e.g. `ghcr.io/org/ci-runner-image:latest`.
  For a private image, set the registry server and username and save a registry
  token; the host runs `docker login` before provisioning. For `ghcr.io`,
  leaving the registry token blank reuses your GitHub token (it just needs
  `read:packages`).

Below that, configure the **warm caches** (host-subdir → container-path mounts;
defaults cover pnpm/npm/yarn/Playwright), the **workspace root**, and the
**Docker-in-Docker mode**.

![Runner image source, warm cache mounts, workspace root, and Docker-in-Docker mode](images/2-runner-image-storage-docker.png)

### 3. (Optional) Turn on queue-aware autoscaling

Set a **min** and **max** runner count, a **warm idle buffer**, an **autoscale
step**, a **demand check interval**, and a **scale-down grace** period. The
daemon adds runners when jobs are queued and removes idle ones once the grace
window passes — so you keep capacity ready without leaving the whole fleet
running around the clock.

![Autoscaling controls: min/max runners, idle buffer, step, check interval, scale-down grace](images/3-autoscaling.png)

### 4. Save your token, validate, and start the fleet

Save a GitHub **Personal Access Token** (`repo` scope; add `admin:org` for org
runners). It's stored at `/boot/config/plugins/ci-runner-farm/token` with
`chmod 600` and is **never** written into your plugin config. Then use the fleet
controls — **Start / Stop / Restart / Scale / Validate** — and watch live
per-runner status (state, phase, CPU, memory). The **Runner image builder**
panel lets you edit the Dockerfile and rebuild right from the page.

![Fleet control buttons, live runner status, secure token storage, and the runner image builder](images/4-fleet-control-image-builder.png)

### 5. Confirm it's running

Once started, the runners show up as ordinary Docker containers
(`ci-runner-1…N`), plus the optional `ci-runner-mirror` registry mirror — each
with the warm-cache bind mounts you configured. Your runners register with
GitHub and start picking up jobs.

![Running ci-runner containers with warm-cache volume mappings and the registry mirror](images/5-running-containers.png)

---

## A word on security

Self-hosted runners execute arbitrary workflow code on your hardware, so a few
rules matter:

- DinD runners run `--privileged`, and shared-socket mode gives runners
  root-equivalent access to the host. Use self-hosted runners **only for
  trusted/private repositories**. Fork-PR code from public repos must **never**
  run on a privileged or socket-mounted self-hosted runner.
- For stronger isolation, set `EPHEMERAL=true` so each job gets a clean runner.
- At org scope, create a **runner group restricted to your private repos** so a
  public repo can never schedule onto these runners.

See GitHub's [self-hosted runner security guidance](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners#self-hosted-runner-security)
for the full picture.

---

## Get it

- **Community Applications:** search **CI Runner Farm** and click Install.
- **Install by URL:** `https://github.com/unraid/ci-runner-farm/releases/latest/download/ci-runner-farm.plg`
  (Unraid resolves this to the newest release and keeps it updated.)
- **Source & issues:** <https://github.com/unraid/ci-runner-farm>
- **License:** BSD-2-Clause.

Spin it up, point it at a repo, and watch your next push build on your own
hardware.
