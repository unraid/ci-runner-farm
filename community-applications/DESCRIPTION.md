# CI Runner Farm — Community Applications copy

Ready-to-paste marketing/description text for the Community Applications listing
and the Unraid support-forum thread. Keep this in sync with the `<Description>`
in [`ci-runner-farm.xml`](ci-runner-farm.xml).

---

## One-liner (CA tagline)

Turn your Unraid box into a fleet of GitHub Actions or GitLab CI/CD self-hosted
build runners — concurrent, cached, autoscaling, and container-only.

---

## Short description (CA listing `<Description>`)

Turn your Unraid server into a fleet of **GitHub Actions or GitLab CI/CD
self-hosted build runners** — multiple concurrent, resource-capped runner slots
as Docker containers (no VM), with warm shared caches on a fast pool,
idle-buffer autoscaling, and Docker-in-Docker for services and image builds.

Select one active provider, save a GitHub PAT or modern GitLab `glrt-` runner
token, and run CI on your own hardware. GitLab mode uses the official Runner
manager and Docker executor; GitHub mode retains the existing runner-container
workflow. Everything is configured from a single webGUI page.

> **Security:** self-hosted runners execute arbitrary workflow code on your
> hardware, and DinD runners run privileged. A private per-slot daemon avoids
> exposing Unraid's existing Docker socket but is not a host security boundary.
> Use runners **only for trusted/private
> projects/repositories** — never let public fork or merge-request code run on a
> privileged self-hosted runner. Enforce protected runners, tags, groups, and
> private scope in the selected CI provider.

---

## Forum support-thread post (BBCode)

```bbcode
[b]CI Runner Farm[/b] turns your Unraid server into a fleet of GitHub Actions or
GitLab CI/CD self-hosted [i]build[/i] runners — multiple concurrent,
resource-capped runner slots as Docker containers (no VM required).

[b]What you get[/b]
[list]
[*][b]N concurrent runners[/b] — each its own container, optionally capped with --cpus/--memory so CI never starves the rest of the host.
[*][b]Idle-buffer autoscaling[/b] — the fleet floats between a configured min and max while retaining warm idle capacity.
[*][b]Warm shared caches[/b] — pnpm/npm/yarn/Playwright caches live on a fast pool and are reused across every run.
[*][b]Docker-in-Docker per runner[/b] — jobs using services: or docker compose just work, with an optional shared pull-through image mirror.
[*][b]Bring your own image[/b] — build one from the in-plugin editor, or pull any registry image (public or private).
[*][b]Two providers, one webGUI[/b] — provider-specific credential storage, Start/Stop/Restart/Scale, live status, and job-image builds. No shell required.
[/list]

[b]Requirements[/b]
[list]
[*]Unraid 6.12.0 or newer, with Docker enabled and a pool (cache) for the runner data root.
[*]A GitHub Personal Access Token, or a modern GitLab runner authentication token beginning glrt-.
[/list]

[b]⚠ Security — read before use[/b]
Self-hosted runners run arbitrary workflow code on your hardware, and DinD
runners run [b]--privileged[/b]. Per-slot DinD limits ordinary Docker access to
one slot, but it is not a security boundary against the Unraid host. Use runners
[b]only for trusted/private repos[/b].
Public fork/MR code must [b]never[/b] run on a privileged or socket-mounted
self-hosted runner. Restrict the runner to trusted private projects or
repositories in GitHub or GitLab.

[b]Source & issues:[/b] https://github.com/unraid/ci-runner-farm
```

---

## Categories

`Tools:System Plugins: Productivity: Network:Management:`

## Screenshots

Additional images available under `docs/images/` in the repo:
`fleet.png` (used as the CA screenshot), `settings.png`, `runner-image.png`,
`fleet-log-drawer.png`.
