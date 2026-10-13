# Shared capacity allocator

CI Runner Farm exports `github.com/unraid/ci-runner-farm/pkg/sharedcapacity`
for workloads that share one host CPU and memory budget. The module requires
Go 1.26 or later. Run `go test -race ./...` and `go vet ./...` from the repository
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
