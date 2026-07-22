# CI Runner Farm — Community Applications copy

Ready-to-paste marketing/description text for the Community Applications listing
and the Unraid support-forum thread. Keep this in sync with the `<Description>`
in [`ci-runner-farm.xml`](ci-runner-farm.xml).

---

## One-liner (CA tagline)

Turn your Unraid box into a fleet of GitHub Actions self-hosted build runners —
concurrent, cached, autoscaling, container-only. Zero cost per CI minute.

---

## Short description (CA listing `<Description>`)

Turn your Unraid server into a fleet of **GitHub Actions self-hosted BUILD
runners** — multiple concurrent, resource-capped runners running as Docker
containers (no VM), with warm shared caches on a fast pool, queue-aware
autoscaling, and Docker-in-Docker so jobs that use `services:` and `docker build`
just work.

Point it at a repo or organization, paste a GitHub token, and your CI runs on
your own hardware — as many jobs in parallel as your box can handle, with
pnpm/npm/yarn/Playwright caches that stay hot between runs, at zero cost per
minute. Everything is configured from a single webGUI page.

> **Security:** self-hosted runners execute arbitrary workflow code on your
> hardware, and DinD runners run privileged. Use them **only for trusted/private
> repositories** — never let public/fork-PR code run on a privileged self-hosted
> runner. The plugin actively warns you when a privileged runner is pointed at a
> public repo.

---

## Forum support-thread post (BBCode)

```bbcode
[b]CI Runner Farm[/b] turns your Unraid server into a fleet of GitHub Actions
self-hosted [i]build[/i] runners — multiple concurrent, resource-capped runners
as Docker containers (no VM required).

[b]What you get[/b]
[list]
[*][b]N concurrent runners[/b] — each its own container, optionally capped with --cpus/--memory so CI never starves the rest of the host.
[*][b]Queue-aware autoscaling[/b] — the fleet floats between a min and max by how many jobs are waiting.
[*][b]Warm shared caches[/b] — pnpm/npm/yarn/Playwright caches live on a fast pool and are reused across every run.
[*][b]Docker-in-Docker per runner[/b] — jobs using services: or docker compose just work, with an optional shared pull-through image mirror.
[*][b]Bring your own image[/b] — build one from the in-plugin editor, or pull any registry image (public or private).
[*][b]One webGUI page[/b] — token storage, Start/Stop/Restart/Scale, live status, and image builds. No shell required.
[/list]

[b]Requirements[/b]
[list]
[*]Unraid 6.12.0 or newer, with Docker enabled and a pool (cache) for the runner data root.
[*]A GitHub Personal Access Token (repo scope; +admin:org for org-wide runners).
[/list]

[b]⚠ Security — read before use[/b]
Self-hosted runners run arbitrary workflow code on your hardware, and DinD
runners run [b]--privileged[/b]. Use them [b]only for trusted/private repos[/b].
Fork-PR code from a public repo must [b]never[/b] run on a privileged or
socket-mounted self-hosted runner. The plugin warns you if it detects a public
repo target on a privileged fleet.

[b]Source & issues:[/b] https://github.com/unraid/ci-runner-farm
```

---

## Categories

`Tools:System Plugins: Productivity: Network:Management:`

## Screenshots

Additional images available under `docs/images/` in the repo:
`fleet.png` (used as the CA screenshot), `settings.png`, `runner-image.png`,
`fleet-log-drawer.png`.
