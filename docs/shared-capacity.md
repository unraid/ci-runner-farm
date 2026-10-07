# Shared host admission

The native farm can delegate build-slot admission to the QA provider's shared
resource broker. This integration requires a compatible `qa-vm-service` binary,
an active provider policy that matches the durable signed host plan, and an
initialized ledger containing the complete inventory of existing workloads.

The deployment-owned `shared-capacity.enabled` marker selects this contract.
Do not install the marker until all owner start paths are closed, their lifecycle
locks are held, and complete workload adoption has succeeded. This branch does
not yet implement the complete deployment and owner adoption procedure.

The `admission-close` command persists a private `shared-capacity.closed` marker
under the native fleet lock. Every build start and recovery path checks this
marker, including legacy mode, while existing workers continue. A broken marker
symlink also closes starts. Keep starts closed through complete owner adoption;
activation must prove the full owner inventory before reopening them.

The supported farm layout is one GitHub pool named `build`, with eight stable
slots at most. Docker enforces each policy allocation's CPU and memory limits;
the provider rejects unlimited or mismatched containers. The provider defaults
to 12 GiB builders and supports a reviewed policy using 12–16 GiB builders.

With autoscaling enabled, each native tick retries the stable slots up to the
pool maximum. The broker decides which may run. Docker creates an inert
container first, then `farm-capacity start NAME ID` checks immutable ownership,
persists its fenced grant and starts the exact ID under the inherited fleet
lock. Exit 75 means queued demand, which preserves its age across retries.
An uncertain start retains its grant and receipt; it cannot start a replacement
with the old allocation. Recycle, stopped-container recovery and self-heal use
the same admission gate. Standalone validation containers are disabled while
this contract is active because they have no reviewed resource allocation.

Removal runs through the native provider adapter before `farm-capacity release
NAME ID`. Release rejects Docker errors, a surviving old container, a replacement
under the same name and stale owner receipts. Capacity never expires on a timer.
Legacy hosts without the marker retain their existing lifecycle behavior.

Each shared autoscale tick first runs `farm-capacity rebalance`. It selects only
positively idle extra builders above the four-builder floor when higher-priority
QA demand is queued. The provider persists withdrawal intent, freezes the exact
container, proves one native `Runner.Listener` and no `Runner.Worker`, and checks
the exact remote registration before deleting it. A pickup race resumes the
worker without releasing its allocation. Unknown local or remote state retains
capacity for recovery.

After authoritative registration removal, withdrawal waits 75 seconds so an
unpicked GitHub assignment can requeue. The container stays frozen and charged.
A later tick repeats ownership and idle proof, removes the exact frozen
container, then releases its fenced grant only after both its ID and stable name
are absent. Restart recovery uses durable effect boundaries; it never thaws a
withdrawn identity. A settling withdrawal prevents selecting another subset for
the same pressure on every tick.
