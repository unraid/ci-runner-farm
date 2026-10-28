# Changelog

## [1.16.1](https://github.com/unraid/ci-runner-farm/compare/v1.16.0...v1.16.1) (2026-10-26)


### Bug Fixes

* **github:** authenticate cold images before queued runner startup ([#189](https://github.com/unraid/ci-runner-farm/issues/189)) ([e2cf880](https://github.com/unraid/ci-runner-farm/commit/e2cf880dd2e7a0ac80d34a9dc6af8497e2924828))
* **github:** preserve empty remote image fallback ([#191](https://github.com/unraid/ci-runner-farm/issues/191)) ([e8a727f](https://github.com/unraid/ci-runner-farm/commit/e8a727fca37b82ad506894f6b987762110bcc6fb))

## [1.16.0](https://github.com/unraid/ci-runner-farm/compare/v1.15.1...v1.16.0) (2026-10-24)


### Features

* **github:** authenticate the farm as a GitHub App ([#186](https://github.com/unraid/ci-runner-farm/issues/186)) ([001b7df](https://github.com/unraid/ci-runner-farm/commit/001b7df6fe3132e3ab1585dafd1546c966a32c32))

## [1.15.1](https://github.com/unraid/ci-runner-farm/compare/v1.15.0...v1.15.1) (2026-10-23)


### Bug Fixes

* **github:** revalidate GitHub reads and pause background polling near the rate limit ([#181](https://github.com/unraid/ci-runner-farm/issues/181)) ([46369c4](https://github.com/unraid/ci-runner-farm/commit/46369c45f810d0b48b83ecd0fe2ab98ae3f020dc))

## [1.15.0](https://github.com/unraid/ci-runner-farm/compare/v1.14.0...v1.15.0) (2026-10-22)


### Features

* **runner:** pin runners to CPU sets sized to their CPU limit ([#179](https://github.com/unraid/ci-runner-farm/issues/179)) ([f431701](https://github.com/unraid/ci-runner-farm/commit/f431701877747d289bed316889adf999cc67e1c8))


### Bug Fixes

* **capacity:** retry the queued head and granted unstarted builders ([#180](https://github.com/unraid/ci-runner-farm/issues/180)) ([1d6b3f8](https://github.com/unraid/ci-runner-farm/commit/1d6b3f851d88d4a0606c75581d342c23eb0f54b3))
* **capacity:** route native OS pools through demand admission ([#184](https://github.com/unraid/ci-runner-farm/issues/184)) ([112d718](https://github.com/unraid/ci-runner-farm/commit/112d718a3103a15f8e7ea88a33f362f2c75bf271))

## [1.14.0](https://github.com/unraid/ci-runner-farm/compare/v1.13.0...v1.14.0) (2026-10-15)


### Features

* **capacity:** expand shared pools without resetting active owners ([#171](https://github.com/unraid/ci-runner-farm/issues/171)) ([8b788b4](https://github.com/unraid/ci-runner-farm/commit/8b788b4b9b408c2f390bfa6a6f364844f6cbba51))


### Bug Fixes

* **cache:** drop idle workspace checkouts under storage pressure ([#173](https://github.com/unraid/ci-runner-farm/issues/173)) ([0d0c345](https://github.com/unraid/ci-runner-farm/commit/0d0c3458afb8809cf4bdca1bafcfdfe368ac3453))
* **cache:** prune persistent DinD stores between jobs ([#172](https://github.com/unraid/ci-runner-farm/issues/172)) ([e166498](https://github.com/unraid/ci-runner-farm/commit/e166498327906577d50d706c520eb972867ced46))
* **cache:** reclaim opted-in unused builder caches under pressure ([#170](https://github.com/unraid/ci-runner-farm/issues/170)) ([bd6d478](https://github.com/unraid/ci-runner-farm/commit/bd6d4789867a00b7ada44cdc586f617b1ad52bb0))
* **capacity:** drain owners above a lowered class ceiling ([#175](https://github.com/unraid/ci-runner-farm/issues/175)) ([1f4aa86](https://github.com/unraid/ci-runner-farm/commit/1f4aa8656fa6c701ef5069f90c1153bcd8567fa0))
* **capacity:** parse runner process names that contain spaces ([#174](https://github.com/unraid/ci-runner-farm/issues/174)) ([e82212a](https://github.com/unraid/ci-runner-farm/commit/e82212a1d4a5667b9dd4e388c5e76e9bae21a36e))
* **capacity:** reconcile idle native runners without clearing warm caches ([#168](https://github.com/unraid/ci-runner-farm/issues/168)) ([9606597](https://github.com/unraid/ci-runner-farm/commit/96065971e02b008bbc7fee234f1f14264ac8da15))
* **capacity:** stop timing windows from discarding demand ticks ([#176](https://github.com/unraid/ci-runner-farm/issues/176)) ([05e6e06](https://github.com/unraid/ci-runner-farm/commit/05e6e06d01e5e9a39a72613dd103689160e7b183))

## [1.13.0](https://github.com/unraid/ci-runner-farm/compare/v1.12.0...v1.13.0) (2026-10-14)


### Features

* **capacity:** initialize standalone native ownership safely ([#166](https://github.com/unraid/ci-runner-farm/issues/166)) ([ace5589](https://github.com/unraid/ci-runner-farm/commit/ace55898aeddd1f30d65ccec40cdb8a939cb88a7))
* **capacity:** pin consumer policy through outer operations ([#163](https://github.com/unraid/ci-runner-farm/issues/163)) ([930f19f](https://github.com/unraid/ci-runner-farm/commit/930f19f6d0653ada570e006630f5d8fdef05b0e3))
* **capacity:** preserve warm recovery in Farm controller ([#159](https://github.com/unraid/ci-runner-farm/issues/159)) ([3b89bfc](https://github.com/unraid/ci-runner-farm/commit/3b89bfcced74b36f91b35b0af2ca960cac73a7c6))


### Bug Fixes

* **capacity:** admit shared workloads against resident memory ([#167](https://github.com/unraid/ci-runner-farm/issues/167)) ([0968814](https://github.com/unraid/ci-runner-farm/commit/09688146ccfef5174ea2b81b69bd0a1ddda98f26))
* **capacity:** release completed builder grants promptly ([#161](https://github.com/unraid/ci-runner-farm/issues/161)) ([4239ea3](https://github.com/unraid/ci-runner-farm/commit/4239ea3976a11d9faf7ff666b456ff26755ad214))
* fence optional shared memory admission across workload starts ([#164](https://github.com/unraid/ci-runner-farm/issues/164)) ([c7927f7](https://github.com/unraid/ci-runner-farm/commit/c7927f7991f0731a4465798e7ec6860c0132e236))
* route Farm-owned hosts through the native controller ([#165](https://github.com/unraid/ci-runner-farm/issues/165)) ([a5e2d35](https://github.com/unraid/ci-runner-farm/commit/a5e2d353c2e7475c3a57d80ddd5cb9bbe04c810a))

## [1.12.0](https://github.com/unraid/ci-runner-farm/compare/v1.11.1...v1.12.0) (2026-10-13)


### Features

* **capacity:** package the Farm-owned native controller ([#155](https://github.com/unraid/ci-runner-farm/issues/155)) ([6008f45](https://github.com/unraid/ci-runner-farm/commit/6008f4507b046e08c6dd343d7b3b2798070afbe2))


### Bug Fixes

* bound GitHub polling and restore Settings rendering ([#157](https://github.com/unraid/ci-runner-farm/issues/157)) ([a08f0f5](https://github.com/unraid/ci-runner-farm/commit/a08f0f53bdb20780d4490c89ba1dc240a3055550))
* **capacity:** preserve controller executable mode on install ([#158](https://github.com/unraid/ci-runner-farm/issues/158)) ([5047c70](https://github.com/unraid/ci-runner-farm/commit/5047c7040ca5d35bb171cf1196979b404c92139e))

## [1.11.1](https://github.com/unraid/ci-runner-farm/compare/v1.11.0...v1.11.1) (2026-10-13)


### Bug Fixes

* **autoscale:** count documented unassigned queued jobs ([#150](https://github.com/unraid/ci-runner-farm/issues/150)) ([e3e4c11](https://github.com/unraid/ci-runner-farm/commit/e3e4c110d5da6aef7181d1d78d4dabe0180a02c4))
* **autoscale:** ignore foreign jobs before assignment guard ([#146](https://github.com/unraid/ci-runner-farm/issues/146)) ([dccba16](https://github.com/unraid/ci-runner-farm/commit/dccba164394ed69e80c41729b69cf8e0e901f93a))
* **scaling:** restore warm builders before queue observation ([#154](https://github.com/unraid/ci-runner-farm/issues/154)) ([a006af1](https://github.com/unraid/ci-runner-farm/commit/a006af1ad794f4f8a70411b1d6128621c6331958))
* **storage:** reclaim completed runner caches under disk pressure ([#148](https://github.com/unraid/ci-runner-farm/issues/148)) ([5e8453b](https://github.com/unraid/ci-runner-farm/commit/5e8453b456537c88e6f66c9a01f65130ab99353f))

## [1.11.0](https://github.com/unraid/ci-runner-farm/compare/v1.10.3...v1.11.0) (2026-10-13)


### Features

* **cache:** expose shared storage to isolated builders ([#143](https://github.com/unraid/ci-runner-farm/issues/143)) ([f52d2f5](https://github.com/unraid/ci-runner-farm/commit/f52d2f536eb8424b7e3d06cbe8e7628ff4c84a3d))
* **capacity:** grow general classes from occupied warm slots ([#138](https://github.com/unraid/ci-runner-farm/issues/138)) ([1d0fb7c](https://github.com/unraid/ci-runner-farm/commit/1d0fb7cc886a548cf1d8a8044174a3ff765da6ea))
* **capacity:** share named build-slot admission with QA ([#133](https://github.com/unraid/ci-runner-farm/issues/133)) ([cae417f](https://github.com/unraid/ci-runner-farm/commit/cae417fc584920c2c5d2f750e09358bcb0fbf9b0))
* **capacity:** use protected host budgets for named build pools ([#136](https://github.com/unraid/ci-runner-farm/issues/136)) ([3db67c8](https://github.com/unraid/ci-runner-farm/commit/3db67c83447eac251225520ce23fe6671b7740dc))
* enforce runner job lifecycle cleanup ([#122](https://github.com/unraid/ci-runner-farm/issues/122)) ([57f2a7a](https://github.com/unraid/ci-runner-farm/commit/57f2a7ad621d3a52134bb4df44a8f56d57c28873))
* **farm:** admit build jobs through bounded size pools ([#135](https://github.com/unraid/ci-runner-farm/issues/135)) ([647dc1c](https://github.com/unraid/ci-runner-farm/commit/647dc1ce272299cb7b1dfc3534fe188ed01237b7))
* publish CI Runner Farm nightly plugin ([5de8d4e](https://github.com/unraid/ci-runner-farm/commit/5de8d4e4dc95059bc8a00ebd2fc7e30b90edb5e3))
* **recommendations:** add historical job-weight tracking ([#121](https://github.com/unraid/ci-runner-farm/issues/121)) ([df73a68](https://github.com/unraid/ci-runner-farm/commit/df73a68f19f7d8cf23bc66e47ff83b8654d13c3d))
* **runners:** support configurable user-share mounts ([c2abfbc](https://github.com/unraid/ci-runner-farm/commit/c2abfbc71d16ac7ef2f6db10394db329da9fe4a3))
* **scaling:** own general build queue observation and sizing ([#145](https://github.com/unraid/ci-runner-farm/issues/145)) ([aa87d3e](https://github.com/unraid/ci-runner-farm/commit/aa87d3e7010642e606ef9a2b9cb694f63cff31c4))


### Bug Fixes

* **cache:** guard shared package cache maintenance ([#141](https://github.com/unraid/ci-runner-farm/issues/141)) ([0bf44ba](https://github.com/unraid/ci-runner-farm/commit/0bf44ba0ce330ffd5119e02fb8eec69eacc8c10d))
* **cache:** release inherited maintenance lock in background refresh ([#142](https://github.com/unraid/ci-runner-farm/issues/142)) ([5ad0df0](https://github.com/unraid/ci-runner-farm/commit/5ad0df0db225c734c617b612f3b8f8b917589ff1))
* **capacity:** retry gated starts after incomplete rebalance ([#139](https://github.com/unraid/ci-runner-farm/issues/139)) ([6dbf43c](https://github.com/unraid/ci-runner-farm/commit/6dbf43cebdfc8f2ea89a62cf069299e0937f337c))
* **github:** opt in runner pools to KVM ([#126](https://github.com/unraid/ci-runner-farm/issues/126)) ([ca8e184](https://github.com/unraid/ci-runner-farm/commit/ca8e1848320e75bbbca99c9e111867dcb302fbe9))
* **github:** recover exited slots without recycling live listeners ([#134](https://github.com/unraid/ci-runner-farm/issues/134)) ([ae71bd9](https://github.com/unraid/ci-runner-farm/commit/ae71bd9b8490bb44f660dd361d01b9c323fcee7d))
* **github:** use the mounted pnpm store across workspace filesystems ([#131](https://github.com/unraid/ci-runner-farm/issues/131)) ([f029b93](https://github.com/unraid/ci-runner-farm/commit/f029b9320c17aee4a47152adbc6a89c57fe9361b))
* **image-update:** roll when runners are on a superseded image ([#119](https://github.com/unraid/ci-runner-farm/issues/119)) ([535a0b3](https://github.com/unraid/ci-runner-farm/commit/535a0b31dbda21c3941f5ef20ee1b3e64c671a51))
* **runners:** prevent shared runner freeze deadlocks ([#144](https://github.com/unraid/ci-runner-farm/issues/144)) ([2df0da0](https://github.com/unraid/ci-runner-farm/commit/2df0da0dc24b9a64976b8619af1d53801b62c95d))
* target dedicated public nightly runner group ([8ad6e67](https://github.com/unraid/ci-runner-farm/commit/8ad6e67f81500209ac1519ebe20ea331ee7737d8))
* use Unraid plugin installer command ([5dc1c3c](https://github.com/unraid/ci-runner-farm/commit/5dc1c3c7125ddc1a88c2b5e207b1eb51e445482a))

## [1.10.3](https://github.com/unraid/ci-runner-farm/compare/v1.10.2...v1.10.3) (2026-09-14)


### Bug Fixes

* **farm:** isolate DinD cgroup namespaces ([#117](https://github.com/unraid/ci-runner-farm/issues/117)) ([e6d2d5e](https://github.com/unraid/ci-runner-farm/commit/e6d2d5e57079945198d776db4c4dfbe94172ccdb))

## [1.10.2](https://github.com/unraid/ci-runner-farm/compare/v1.10.1...v1.10.2) (2026-09-02)


### Bug Fixes

* **autoscale:** use fresh queue depth for growth ([#88](https://github.com/unraid/ci-runner-farm/issues/88)) ([cd57608](https://github.com/unraid/ci-runner-farm/commit/cd576085f052e1473c7fd9c0825f85235e0641cf)), closes [#80](https://github.com/unraid/ci-runner-farm/issues/80)
* **build:** preserve modes in dev package render ([#87](https://github.com/unraid/ci-runner-farm/issues/87)) ([06184ed](https://github.com/unraid/ci-runner-farm/commit/06184ed9e97361b91ae471e5c0fa8094027caea5))
* **build:** XML-escape changelog text ([#94](https://github.com/unraid/ci-runner-farm/issues/94)) ([768ef89](https://github.com/unraid/ci-runner-farm/commit/768ef89b422b426979aa2c9a00cc40c8eefe29d1))
* **editors:** exclude LICENSE from formatting rules ([#89](https://github.com/unraid/ci-runner-farm/issues/89)) ([4f82bb1](https://github.com/unraid/ci-runner-farm/commit/4f82bb1d8b3829b101cb29987c23e333c1670669)), closes [#72](https://github.com/unraid/ci-runner-farm/issues/72)
* **github:** fail validation on setup errors ([#93](https://github.com/unraid/ci-runner-farm/issues/93)) ([7bc43ac](https://github.com/unraid/ci-runner-farm/commit/7bc43ac1fa5380d837aac768bf465115dbc04543))
* **image:** validate remote Docker image references ([#91](https://github.com/unraid/ci-runner-farm/issues/91)) ([c037d84](https://github.com/unraid/ci-runner-farm/commit/c037d84cec70e5f684d18eded547f770c46805e9)), closes [#64](https://github.com/unraid/ci-runner-farm/issues/64)
* **logging:** bound persistent boot log size ([#90](https://github.com/unraid/ci-runner-farm/issues/90)) ([bf42747](https://github.com/unraid/ci-runner-farm/commit/bf42747f722a8c472bdd2c5d75c4853024c06aab)), closes [#62](https://github.com/unraid/ci-runner-farm/issues/62)
* **secrets:** report successful atomic credential writes ([#96](https://github.com/unraid/ci-runner-farm/issues/96)) ([25b9e45](https://github.com/unraid/ci-runner-farm/commit/25b9e45c8626558f9946f837a49fed7414c7f5f0))
* **selfheal:** detect missing BuildKit snapshots ([#86](https://github.com/unraid/ci-runner-farm/issues/86)) ([6622ad9](https://github.com/unraid/ci-runner-farm/commit/6622ad93299a434685195fb8f5f4c9c8ed5dbe71))
* **shell:** harden temporary paths and Docker pull args ([#92](https://github.com/unraid/ci-runner-farm/issues/92)) ([454b651](https://github.com/unraid/ci-runner-farm/commit/454b651ecb116fd64ee4b514588bdf6272770105))
* **web:** handle invalid UTF-8 at output boundaries ([#95](https://github.com/unraid/ci-runner-farm/issues/95)) ([827903e](https://github.com/unraid/ci-runner-farm/commit/827903e240f8bc2583a96c0b9d13755d0f27b031))

## [1.10.1](https://github.com/unraid/ci-runner-farm/compare/v1.10.0...v1.10.1) (2026-08-27)


### Bug Fixes

* **release:** publish validated plugin assets from the release tag ([#84](https://github.com/unraid/ci-runner-farm/issues/84)) ([65b10a6](https://github.com/unraid/ci-runner-farm/commit/65b10a652ce98424ca407157aad9e7d10dc1a3ab))

## [1.10.0](https://github.com/unraid/ci-runner-farm/compare/v1.9.1...v1.10.0) (2026-08-27)


### Features

* add .editorconfig and VS Code editor settings ([#69](https://github.com/unraid/ci-runner-farm/issues/69)) ([a8d6aac](https://github.com/unraid/ci-runner-farm/commit/a8d6aac2cdf3f41c0540bced687bb97d0bdc3e36)), closes [#65](https://github.com/unraid/ci-runner-farm/issues/65)
* add provider-neutral runner pools ([#74](https://github.com/unraid/ci-runner-farm/issues/74)) ([2fbc077](https://github.com/unraid/ci-runner-farm/commit/2fbc07781df3d0f537d9cf17603bb0088eb1656c))
* **autoscale:** self-heal runners poisoned by dangling buildkit leases ([#73](https://github.com/unraid/ci-runner-farm/issues/73)) ([e0190e5](https://github.com/unraid/ci-runner-farm/commit/e0190e5a82c6ea3c476950386cc2015138fb5c52))


### Bug Fixes

* allow colocated QA VM transport ([#77](https://github.com/unraid/ci-runner-farm/issues/77)) ([a96940a](https://github.com/unraid/ci-runner-farm/commit/a96940a5dc85006019c4bef81418a697aacc7c85))
* **github:** expose local farm host gateway ([#75](https://github.com/unraid/ci-runner-farm/issues/75)) ([b001402](https://github.com/unraid/ci-runner-farm/commit/b001402eee748753625ffb610484894c4d704fab))
* **github:** route colocated services to local farm ([#76](https://github.com/unraid/ci-runner-farm/issues/76)) ([30eb3b5](https://github.com/unraid/ci-runner-farm/commit/30eb3b552d130398b3b0b91a43940b9f92e9bf1b))
* surface docker run stderr when a recycle replacement fails ([#82](https://github.com/unraid/ci-runner-farm/issues/82)) ([8b5e01f](https://github.com/unraid/ci-runner-farm/commit/8b5e01fb31e404c8baef7188a6e3b89e186c304c))

## [1.9.1](https://github.com/unraid/ci-runner-farm/compare/v1.9.0...v1.9.1) (2026-08-12)


### Bug Fixes

* add .gitattributes to pin line endings to LF ([#52](https://github.com/unraid/ci-runner-farm/issues/52)) ([4c70b12](https://github.com/unraid/ci-runner-farm/commit/4c70b12fcb2e15da92ae9a72a8422cc66b0638c6)), closes [#50](https://github.com/unraid/ci-runner-farm/issues/50)
* **config:** validate numeric config values at parse time ([#57](https://github.com/unraid/ci-runner-farm/issues/57)) ([d24af37](https://github.com/unraid/ci-runner-farm/commit/d24af379c0a80a51992ac90c77f1a39ba0feeca8))
* **github:** keep the runner registration token out of docker argv ([#58](https://github.com/unraid/ci-runner-farm/issues/58)) ([81b7b2d](https://github.com/unraid/ci-runner-farm/commit/81b7b2d84bf892aa2444dae7905ae62e83933913))
* **gitlab:** harden API redirects and CSRF compatibility ([#46](https://github.com/unraid/ci-runner-farm/issues/46)) ([ad1e5fa](https://github.com/unraid/ci-runner-farm/commit/ad1e5faf4e8cdc851eb7f53504fd1583859b6c66))
* pin release-please-action to a commit, bump actions/checkout, annotate all pins ([#53](https://github.com/unraid/ci-runner-farm/issues/53)) ([703459a](https://github.com/unraid/ci-runner-farm/commit/703459a1e5d67b0aed51a3c12cb36b46cde257f8))
* **web:** redact secrets on every path that reaches the browser ([#59](https://github.com/unraid/ci-runner-farm/issues/59)) ([19f4796](https://github.com/unraid/ci-runner-farm/commit/19f47960d785d220f98313167b24d9d7294103ce))

## [1.9.0](https://github.com/unraid/ci-runner-farm/compare/v1.8.0...v1.9.0) (2026-08-06)


### Features

* add GitLab runner provider ([#44](https://github.com/unraid/ci-runner-farm/issues/44)) ([ae09e32](https://github.com/unraid/ci-runner-farm/commit/ae09e3256a5e5fc1c69ccb524c0bbdb5207a95da))

## [1.8.0](https://github.com/unraid/ci-runner-farm/compare/v1.7.0...v1.8.0) (2026-07-30)


### Features

* **auth:** add PAT scope presets ([#42](https://github.com/unraid/ci-runner-farm/issues/42)) ([15f073e](https://github.com/unraid/ci-runner-farm/commit/15f073efe45d5874f2dd05cf17802bfee102484a))

## [1.7.0](https://github.com/unraid/ci-runner-farm/compare/v1.6.0...v1.7.0) (2026-07-24)


### Features

* fleet hardening, Main dashboard widget, live config migration ([#40](https://github.com/unraid/ci-runner-farm/issues/40)) ([e74875b](https://github.com/unraid/ci-runner-farm/commit/e74875b414f4f0149fea021bc6196045ae771861))

## [1.6.0](https://github.com/unraid/ci-runner-farm/compare/v1.5.1...v1.6.0) (2026-07-22)


### Features

* **ui:** settings-page facelift — tabbed fleet hub, image builder, cache/stats, native theming (@jmagar) ([#33](https://github.com/unraid/ci-runner-farm/issues/33)) ([fc95b61](https://github.com/unraid/ci-runner-farm/commit/fc95b614c61dc8dca99c68358e67ea428c4a0297))


### Bug Fixes

* **release:** credit commit authors in notes ([#35](https://github.com/unraid/ci-runner-farm/issues/35)) ([7307817](https://github.com/unraid/ci-runner-farm/commit/73078170d2156559b928b30d86e9bf677f857bda))
* **release:** update release-please action ([#38](https://github.com/unraid/ci-runner-farm/issues/38)) ([4a33381](https://github.com/unraid/ci-runner-farm/commit/4a333817291f452a9cb46ea7782334cdca0054d0))

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
