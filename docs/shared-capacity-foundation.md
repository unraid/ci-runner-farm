# Shared capacity allocator

CI Runner Farm exports `github.com/unraid/ci-runner-farm/pkg/sharedcapacity`
for workloads that share one host CPU and memory budget. The module requires
Go 1.26.10 or later. Run `go test -race ./...` and `go vet ./...` from the repository
root. The existing shell/plugin checks remain separate.

This foundation transfers the allocator from
`unraid/qa-lab` commit `5064fd986a6b8a2694fb6a99f06f6bc3e91b4ca7`,
`qa-vm-service/internal/sharedcapacity`. It retains all 16 original test files.
Six production files add package comments for Farm’s file-level lint gate.
One reviewed correction reports an ambiguous remote assignment after withdrawal
intent as a recovery error, rather than claiming that the frozen listener resumed.
It retains the same owner and withdrawal phase. A regression test covers that
boundary. The adoption test also uses a known pool to reach its identity guard.
All other original code stays unchanged. The synthetic v5 compatibility fixture
was produced by the original source.
Its release fences are deterministic test values, not host ownership material.

The ledger persists a grant before its workload starts. A grant remains charged
until its owner proves that the exact workload stopped. A timeout, process exit,
or low utilization does not release a grant. Borrowing preserves physical QA
reserves, per-workload limits and pending-request age. Release requires the same
fence that admission issued. Diagnostics hash fences instead of disclosing them.

Use one policy and one ledger across participants. This library is a trusted
host-local component, not a network admission service or an authentication
boundary. Callers must enforce policy authority and lifecycle ownership. Keep
the ledger private and preserve owner receipts alongside it.

Adding this importable module does not transfer a running host or change the
plugin's current QA-backed CLI integration. The controller and QA participant
must switch together through a reviewed, fenced handoff before Farm becomes
the live budget owner. Do not initialize a replacement ledger, remove ownership
markers, or alter budgets to bypass outstanding grants.

The initial implementation retains the existing `build` memory-borrowing class.
General named-pool support and standalone controller wiring follow separately.


## Native controller package

`pkg/farmcapacity` reuses the native Docker controller, receipts, registration
binding, routing publication and phased withdrawal from the same QA source.
Its only protocol helper change replaces QA's JSON/SHA-256 digest function
with the same encoding in Farm. Native control remains under `fleet.lock`.

The package includes `bin/ci-runner-capacity`, built with Go 1.26.10 for Linux
amd64. Packaging strips checkout paths and VCS state. `version` needs no
provider installation. Lifecycle commands require root, the inherited native
fleet lock and Farm's private `host-capacity.json` configuration. That file
supplies the host identity, ownership epoch, policy, ledger, receipts, token
path and policy lock. Every non-build class must have a declared consumer.
Consumers retain shared policy leases through effects. Policy changes and
handoffs require an exclusive lease. `mode: "closed"` denies mutations.

This controller package does not activate an additional controller. Existing
shell integration stays on its current owner until the participants and ledger
can switch together. A manually written active configuration does not prove
migration. Preserve all existing grants, fences, pending ages and owner receipts.
Old controller commands and old ledger paths must be fenced before admission
reopens. Fresh standalone initialization also requires a complete owner proof;
this stage does not initialize a replacement ledger automatically.

## GitHub request containment

General queued pools run a complete background planning pass at most once every
five minutes, even if the daemon tick is shorter. The protected HTTP cache saves
the attempt before remote work, so failed scans and restarts retain that limit.
Local cache cleanup and running jobs continue during the delay.

Queue responses with 500 or fewer remaining requests defer background work until
the reported reset time. Rate-limit responses also honor `Retry-After`, with at
least five minutes of backoff. These observations do not guarantee a global
reserve when multiple hosts or other clients share the same GitHub identity.
Explicit Start still establishes the retry controllers when capacity is deferred.

This containment reduces polling; native conditional reads and batched planning
remain separate work. Cached queue bodies still require authenticated revalidation,
and denied or partial observations never authorize an empty-queue retirement.
