# Changelog

## [1.5.1](https://github.com/unraid/ci-runner-farm/compare/v1.5.0...v1.5.1) (2026-07-22)


### Bug Fixes

* honor EPHEMERAL=false, enforce autoscale MIN floor, runner-owned cache dirs ([#30](https://github.com/unraid/ci-runner-farm/issues/30)) ([a605b80](https://github.com/unraid/ci-runner-farm/commit/a605b80193cd93ba37ee9849c8ea52ba3110cd45))

## [1.5.0](https://github.com/unraid/ci-runner-farm/compare/v1.4.3...v1.5.0) (2026-07-12)


### Features

* **default-image:** add runner HEALTHCHECK to the shipped starter Dockerfile ([#27](https://github.com/unraid/ci-runner-farm/issues/27)) ([ea6c88d](https://github.com/unraid/ci-runner-farm/commit/ea6c88d0cbb9e8f683610d2c7bd632224fa13367))

## [1.4.3](https://github.com/unraid/ci-runner-farm/compare/v1.4.2...v1.4.3) (2026-07-12)


### Bug Fixes

* **autoscale:** reap disconnected (health=unhealthy) runners, not just exited ([#25](https://github.com/unraid/ci-runner-farm/issues/25)) ([727e4e2](https://github.com/unraid/ci-runner-farm/commit/727e4e2ed0aaf5753f40c82e64e586c5bb7cd1b3))

## [1.4.2](https://github.com/unraid/ci-runner-farm/compare/v1.4.1...v1.4.2) (2026-07-07)


### Bug Fixes

* **plugin:** dedicated .tgz package + Unraid config idioms ([#23](https://github.com/unraid/ci-runner-farm/issues/23)) ([97873dc](https://github.com/unraid/ci-runner-farm/commit/97873dc377e2bea6a46af95f976e45951f17b880))
* recreate runners with a fresh token instead of resurrecting stale ones ([#22](https://github.com/unraid/ci-runner-farm/issues/22)) ([411d5cd](https://github.com/unraid/ci-runner-farm/commit/411d5cd5f24f6602684df8d60148d2807da1d4a2))

## [1.4.1](https://github.com/unraid/ci-runner-farm/compare/v1.4.0...v1.4.1) (2026-07-07)


### Bug Fixes

* land stranded review fixes and release public CA readiness (1.5.0) ([#19](https://github.com/unraid/ci-runner-farm/issues/19)) ([5acc848](https://github.com/unraid/ci-runner-farm/commit/5acc8484fdfc08a399a8d315eadf1d999408c2ee))

## [1.4.0](https://github.com/unraid/ci-runner-farm/compare/v1.3.0...v1.4.0) (2026-07-01)


### Features

* **security:** harden defaults for public Community Apps distribution ([#15](https://github.com/unraid/ci-runner-farm/issues/15)) ([62b9df8](https://github.com/unraid/ci-runner-farm/commit/62b9df8f7f3f9ffa57b5c41b03c0cb86a91bfa16))

## [1.3.0](https://github.com/unraid/ci-runner-farm/compare/v1.2.0...v1.3.0) (2026-06-30)


### Features

* **dind:** bind per-runner diagnostics dir for DinD post-mortem ([#12](https://github.com/unraid/ci-runner-farm/issues/12)) ([9f63027](https://github.com/unraid/ci-runner-farm/commit/9f63027052c2f00305e171feba634228e6b2af21))
* restart the fleet on Unraid Docker stop/start events ([#11](https://github.com/unraid/ci-runner-farm/issues/11)) ([6596c41](https://github.com/unraid/ci-runner-farm/commit/6596c4147ed3423d8a5774c521e819f4d8c81e7b))

## [1.2.0](https://github.com/unraid/ci-runner-farm/compare/v1.1.0...v1.2.0) (2026-06-26)


### Features

* scheduled runner-image auto-update with drain-then-recreate ([#9](https://github.com/unraid/ci-runner-farm/issues/9)) ([3ddaccc](https://github.com/unraid/ci-runner-farm/commit/3ddaccc508994871e8a6556e5fc06576499a4507))

## [1.1.0](https://github.com/unraid/ci-runner-farm/compare/v1.0.0...v1.1.0) (2026-06-24)


### Features

* proper Plugins-page name + icon link to settings ([#8](https://github.com/unraid/ci-runner-farm/issues/8)) ([7f71781](https://github.com/unraid/ci-runner-farm/commit/7f71781fdd4b91a0277246c541e621d1991d8806))
* run jobs as non-root by default with GitHub-hosted storage parity ([#5](https://github.com/unraid/ci-runner-farm/issues/5)) ([159384e](https://github.com/unraid/ci-runner-farm/commit/159384e4dce37efb739703ed7eb13441f35aa4b1))


### Bug Fixes

* **dind:** real-FS Docker data root for runners + FUSE cache-root guard/warning ([#7](https://github.com/unraid/ci-runner-farm/issues/7)) ([1f06c8e](https://github.com/unraid/ci-runner-farm/commit/1f06c8e508d0c537b16e08a91bf773beeb61b9c3))
* **ui:** keep the fleet log panel visible when empty ([#4](https://github.com/unraid/ci-runner-farm/issues/4)) ([79e032d](https://github.com/unraid/ci-runner-farm/commit/79e032d13bf92a2bd30ca4e1c49b9d1417d522a3))

## 1.0.0 (2026-06-24)


### Features

* DinD mode (own dockerd per runner) to fix services: networking + port collisions ([74990ff](https://github.com/unraid/ci-runner-farm/commit/74990ff76a3dc205e973de3f9364e679a04db748))
* fat runner image (warm caches) + graceful stop + package cache ([88f6ce0](https://github.com/unraid/ci-runner-farm/commit/88f6ce0679b72ade9cdf7d0109da4d333df58e90))
* field tooltips + pre-scoped GitHub PAT link; harden deploys to root:root ([e320ca6](https://github.com/unraid/ci-runner-farm/commit/e320ca67c7fc5ecdcb69a7e6d36177e7e1844488))
* generic starter runner image + bring-your-own-image ([d6bcf90](https://github.com/unraid/ci-runner-farm/commit/d6bcf9076fa34d1313886f0a23f7155e3f509754))
* image source selector (built-in vs remote) ([193ec88](https://github.com/unraid/ci-runner-farm/commit/193ec887f819d28559fc81b677e8dc9b1c36b99e))
* in-plugin runner image builder (editable Dockerfile + Build button) ([a996fda](https://github.com/unraid/ci-runner-farm/commit/a996fda19b280d636a1a95561906e7a36074aa62))
* private registry docker login + configurable cache mounts ([87e62c4](https://github.com/unraid/ci-runner-farm/commit/87e62c4d4dc958871dfc008c7cb1e1b2bb0a044e))
* public-release publishing via release-please + GitHub artifacts ([#1](https://github.com/unraid/ci-runner-farm/issues/1)) ([46eb8c1](https://github.com/unraid/ci-runner-farm/commit/46eb8c178a61c256044bea5f689622828c62be8f))
* queue-aware autoscaler with tuning options ([f19cd16](https://github.com/unraid/ci-runner-farm/commit/f19cd16c7ab1fc04d81ccf62b5069d22a7273486))
* **registry:** reuse GitHub PAT for GHCR login when no registry token set ([60d41db](https://github.com/unraid/ci-runner-farm/commit/60d41dbf6d5c56b872cb8db37f2b70be23ce28f4))
* shared image cache (registry mirror) + guard CACHE_ROOT against rootfs ([5aa92d9](https://github.com/unraid/ci-runner-farm/commit/5aa92d9261d7308eae78e06eb365b1416d2b5a2c))
* **ui:** hide remote-only fields unless Image source = Remote ([55e58c3](https://github.com/unraid/ci-runner-farm/commit/55e58c36cb02014bde2526e861e205d59d33248e))
* **ui:** native folder picker on Cache root path field ([4253c75](https://github.com/unraid/ci-runner-farm/commit/4253c75523c6f198caab987285c60cba5d8b8570))


### Bug Fixes

* scope install extraction to plugin dir, force root perms ([bb869cc](https://github.com/unraid/ci-runner-farm/commit/bb869cc7ee266d55795c5b59ade4044a752679cf))
* **ui:** load jquery.filetree js+css so the Cache root picker actually works ([e352946](https://github.com/unraid/ci-runner-farm/commit/e352946d43197d5ab2be8dc69585abe8642ca0ac))
* **ui:** use Unraid native inline help (markdown form + :plug:/&gt;/:end) ([43c52b3](https://github.com/unraid/ci-runner-farm/commit/43c52b323d6ed58a6bee813eae7b24b72a1f208f))

## Changelog

All notable changes to this project are documented here. This file is managed
automatically by [release-please](https://github.com/googleapis/release-please)
from [Conventional Commit](https://www.conventionalcommits.org) messages merged
to `main`.
