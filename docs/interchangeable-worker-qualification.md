# Interchangeable worker qualification

Related issue: [QUA-315](https://linear.app/lime-technology/issue/QUA-315).

A worker may execute either a build or a job-owned Docker/QEMU guest. The job
type does not create a second permanent fleet or reserve another static slice
of the host. Unraid 7 and 8 are workload scenarios, not infrastructure classes.

This document records qualification boundaries. It does not activate a host
policy, install an image, or authorize a fleet cutover. The common manager and
caller adapters remain the production lifecycle owners.

## Inclusive resource boundary

One broker grant covers the worker container's complete hard envelope. A guest
inside that container must fit alongside its runner, tools, hypervisor overhead,
and other job processes. Do not charge the same guest RAM as another external
`qa-guest` grant. A guest outside the charged container is a different topology
and cannot borrow this inclusive accounting claim.

The tests use one `worker` pool and a 48 GiB/16 CPU test budget. Four 12 GiB/four
CPU envelopes fit, regardless of whether request names describe build or guest
jobs. This is a test policy, not a deployment recommendation. The real signed
host policy owns limits, floors, CPU admission mode, and host reserve.

The current common-manager interface specifies a 16 GiB/six CPU worker, an
ordinary 8 GiB guest, the existing 80% memory-headroom check, and a staging guard
of three times boot bytes plus 2 GiB. A 16 GiB guest does not automatically fit
inside that worker. These interface values do not authorize a deployment or
replace the real grant and capability checks.

Broker admission alone cannot enforce a Docker cgroup, limit nested QEMU RAM,
reserve disk space, or prove that a caller uses exactly one grant. Those are
explicit runtime qualification gates below. The current `Resources` contract
contains memory and CPU only; disk capacity is not an implied broker guarantee.

## Contract matrix

| Boundary | Executable evidence | Remaining runtime obligation |
| --- | --- | --- |
| Mixed build and guest demand | `TestInterchangeableWorkerMixedContentionHasOneBudget`: 32 concurrent requests, four grants, 28 pending, exact aggregate limits | Run an actual build and admitted guest concurrently through the common manager |
| Inclusive envelope | `TestInterchangeableWorkerEnvelopeDoesNotAddASecondGuestCharge`: retry preserves one grant; undeclared guest pool refused | Bind manager grant, container cgroup, and QEMU process to one exact job identity; prove overhead fits |
| Immutable retry | `TestInterchangeableWorkerChangedEnvelopeFailsBeforeMutation` | Reject a running job's hardware or owner change through the actual caller |
| Pending start and reserve | `TestInterchangeableWorkerUncertainStartKeepsReserveAcrossRestart`: durable start identity survives reopen; uncertain execution remains charged; confirmation removes only shadow charge | Fresh host and cgroup observations, exact running owner proof, no additional guest charge |
| Cancellation and expiry | `TestInterchangeableWorkerCancellationAndTimeDoNotReleaseOwner`; existing `owned_wait_test.go` | Cancel job demand without releasing a surviving listener; expired lease needs owner proof, not elapsed-time cleanup |
| Simultaneous attempts and stale fences | Concurrent contention test and `TestInterchangeableWorkerUnknownAndDelayedReleaseCannotAffectReplacement` | Exact container/start identity through real retries and replacement |
| Active-job draining | `TestInterchangeableWorkerDrainRetainsBusyAndUnknownOwners`; existing `withdraw_test.go` tests pickup races and durable settlement | Withdraw admission and repeat local/remote idle proof under the existing owner lease before removing only that worker |
| Failed child, surviving listener | `TestInterchangeableWorkerLocalChildFailureCannotReleaseLiveListener`: actual local child exits, actual listener lives, bbolt grant retained; listener stop/reap permits fenced release | Real runner worker failure and independent listener lease renewal; do not infer health from listener alone |
| Process groups | Local fixture creates private Unix process groups, terminates and reaps only its two owned fixtures under finite deadlines | Common manager must prove QEMU, helpers and descendants exit; unit fixtures are not nested guest cleanup proof |
| Host and cgroup enforcement | Existing broker reserve and headroom tests; no cgroup enforcement claim from those tests | Check ancestor `memory.max`, `pids.max`, CPU limits, actual child containment and host reserve before guest start |
| Disk and quota admission | **Open**: no disk field in this broker; no invented RAM-to-disk conversion | Measure relevant ancestor quota and current allocation, reserve bounded private overlays and outputs, refuse insufficient or unknown headroom |
| Shared image cache | **Open in this lane**; common manager owns cache implementation | Concurrent original-image acquisition; interrupted download/publication leaves no visible partial image; immutable hash verified before reuse |
| Private guest identity | **Open in this lane**; common manager and caller own guest resources | Distinct lawful license/identity lease, network, disk overlays, vars and TPM paths; no reused active peer identity |
| Failure cleanup and unknown owner | Fenced release and actual local process test; existing withdrawal uncertainty tests | Retain uncertain resources; prove only exact owned processes, mounts, network and private files are gone before release |
| Normal completion | Broker exact release tested; no production cleanup receipt yet | Actual workload result plus restoration/release proof and surviving peer/listener checks |

## Run the local contract tests

```sh
go test -race ./pkg/sharedcapacity -run TestInterchangeable -count=1
go test -race ./...
go vet ./...
```

The process fixture runs on Unix. It uses separate test processes with private
process groups and a 15-second safety deadline. It does not execute inside a
peer container or start Docker, QEMU, a build, or a provider operation.

Passing these tests proves broker behavior against a real local bbolt ledger
and the stated local process boundary. It does not prove mixed Docker/KVM
runtime behavior, image publication, a booted Unraid scenario, or safe cutover.

## Common-manager source qualification snapshot

The separate manager owner supplied candidate
`b474b9e3f7e0c4fe67bf6f76ad3aee20e8b938e8` from `unraid/ci-runner-image`.
Its `vm/job-vm.py` SHA256 is
`e0f6736127bbc6ed744382966f79e86d908dbc3c6c7260448b1dc708c382f4cb`.
No manager source was changed in this lane.

The candidate's existing `test_job_vm_cache.py` and `test_job_vm_runtime.py`
were executed from an exact source export. On Linux, 22 of 25 cases passed;
three compressed-cache cases explicitly skipped because zstd was unavailable.
On macOS, 21 cases passed, including those compressed-cache cases; four
Linux-only cases explicitly skipped. This is two complementary environments,
not a claim of one all-green Linux run.

The Linux execution used a disposable local container with network disabled,
a read-only source mount and root filesystem, private temporary storage, and
bounded memory/CPU/PIDs. Actual owned process fixtures covered parent SIGKILL,
inherited-lock release, direct and escaped child cleanup, and live PID/birth
handoff refusal after exit. Cache tests covered interrupted publication,
corruption refusal, concurrent compressed fill, timeout reaping and active-cache
protection. Mocked disk and argv assertions remain source-level evidence, not
a booted guest or proof of an actual host quota.

The matrix's runtime gates remain open even where these existing tests provide
additional source and local process evidence. No additional production manager,
admission API, host policy, permanent pool, or runtime observer was introduced.

## First runtime handoff

Before one real guest, the manager owner supplies its qualified image/source
and exact common lifecycle contract. The caller owner supplies verified guest
inputs, explicit hardware and a distinct test-license/identity lease. The
existing admission owner supplies a real grant and current host/cgroup/quota
limits. Busy peers and unknown scratch remain untouched. At most one initial
guest in this lane may run if aggregate admission permits it.

Record build and guest job identities, container ID/start identity, grant fence,
inclusive memory charge, cgroup ancestry, quota, private resource paths, artifact
digests and cleanup receipts. Inject only a job-owned failure through the common
manager's supported lifecycle. A successful local fixture cannot substitute for
any missing runtime evidence. Fleet cutover and host-policy changes remain gated.
