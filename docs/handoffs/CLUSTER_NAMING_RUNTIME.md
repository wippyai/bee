# Runtime cluster and naming handoff

Prepared 2026-09-07 for a separate runtime agent. This is a memory transfer with
source findings and test evidence, not a finished production review or an approved
redesign. The Bee agent continues application/UI work independently.

## Mission

Review Wippy's cluster naming system holistically for production use on roughly
100 nodes on the user's home LAN. Decide whether Raft remains appropriate, what
its precise responsibility should be, and what needs hardening or simplification.
Also assess the runtime primitives required by Bee's multi-workspace, multi-client
native desktop. Fix demonstrated runtime defects in an isolated checkout, with
regressions and a reviewable patch; do not fold Bee product semantics into runtime
just because Bee exposed the question. No merge/deployment has been requested as
part of this handoff. Check current PR state before choosing an upstream branch.

The user explicitly asked:

- Why Raft, and do we actually need it? Their goal was strong consistency for
  name claims. Other agents argued against a distributed log; the user suspects
  proving updates across every host requires an equivalent coordination system.
- Up to 100 nodes total on a home network, including potentially many clients.
- Cluster mode off by default in Bee, enabled through an easy named profile.
- Desired future UX: `bee codex`, and the agent/client joins the configured hive.
  This is a desired command flow, not an implemented driver.
- One native client can attach to applications in several workspaces/nodes,
  arrange tabs freely, and switch projects without moving the execution itself.
- A workspace can span nodes. App definitions/saved overlays may be distributed
  across its nodes; a workspace is not synonymous with a local directory or host.
- Every app/tab must preserve visible workspace identity. One workspace owns
  multiple apps, and multiple clients may attach. Client layout and workspace/app
  ownership must be distinct.
- Dormant projects should not eagerly run agents/watchers/apps or burn idle CPU
  and bandwidth. Do not claim negligible overhead without measurement.
- Optional Kickside components are later extensions. Bee is self-sufficient;
  Kickside compatibility is explicitly NOT a prerequisite for current work.

## Workspace and ownership boundaries

Bee repository: `/home/wolfy-j/wippy/bee`, origin `git@github.com:wippyai/bee.git`.
The user owns it; Bee source is MIT. Upstream runtime files retain MPL-2.0.

Runtime checkout inspected: `/tmp/wippy-mesh-review`.
HEAD: `5371848eb1b4d1aabc49eeda3a10df3c4df6636f`.
This matches Bee's `runtime/lock.json` commit. Bee additionally applies
`runtime/patches/foundation.patch`, checksum:
`aa3ccfb9b78d5ba75e59278a4010ea6eaea3032e0f260fa859a26df680992ec3`.
Go version in the lock: 1.27.0.
Bee's runnable binary: `/home/wolfy-j/wippy/bee/.wippy/bin/wippy`.

The runtime checkout is DIRTY with existing Bee work. Do not reset, overwrite,
stash or commit those changes wholesale. At last inspection it contained changes
in CLI startup/lint/pack/progress, native terminal surface, scheduler shutdown,
TTY revoke idempotency and security type metadata, plus untracked regression tests.
The cluster and naming implementation paths inspected were clean. The checkout
has the right base, but is not itself a clean reproducible build artifact.
Use a separate worktree/clone for new runtime changes, and explicitly select which
existing patches are relevant. Bee's setup script is the reproducible build path.

Earlier conversation mentions runtime PR #653 (mesh terminal surfaces/page colors)
and #655 (shutdown), but CURRENT PR STATES HAVE NOT BEEN CHECKED in this review.
Do not assume they are open or that the branch still equals the pinned commit.

Bee tracked commits before current work:
- `ddf6ba8`: prior desktop baseline.
- `ac339ed`: secure desktop foundation, native Terminal, durable app recovery.
- `b7f6fc5`: documentation/code conventions checkpoint, pushed to origin main.

Bee currently has UNCOMMITTED ongoing application work. Do not edit it from the
runtime task. It includes DOS Blue/Windows Classic themes, selection-text semantics,
updated UI/docs, and an isolated thread example in `examples/threads/` with
`tests/threads.py`. The parent owns these files. A failing naming research
regression lives at `runtime/research/unregister_aba_test.go`; it is an evidence
artifact, not part of the pinned runtime patch or Bee's green test suite.

## Read these runtime sources first

All relative paths in this section are under `/tmp/wippy-mesh-review`:

1. `api/topology/namereg/global/globalreg.go`: public scopes and guarantees.
2. `runtime/lua/modules/process/module.go`: register/lookup/unregister binding,
   particularly around lines 680–735 and 811–868.
3. `system/topology/pid_registry.go`: composed lookup and cross-scope checks.
4. `system/topology/namereg/global/{service.go,commands.go,state.go,fsm.go}`.
5. `system/topology/namereg/global/{strong.go,join_barrier.go,leader_reachability.go}`.
6. `system/topology/namereg/global/{dissem.go,dissem_wiring.go,forward.go,forward_envelope.go}`.
7. `system/topology/namereg/eventual/{service.go,state.go,gc.go,delegate.go}` and tests.
8. `boot/components/system/{cluster.go,raft.go,tty_mesh.go}`.
9. `cluster/internode/{internode.go,manager.go,handshake.go}`.
10. `system/tty/{README.md,mount.go,mesh.go,viewport.go}` and `api/tty/mount.go`.

## What naming actually implements

Four registration scopes are exposed:

| Scope | Implemented intent |
|---|---|
| Local = 0 | Name on one node |
| Eventual = 1 | Gossip/CRDT discovery with eventual conflict resolution |
| Consistent = 2 | Raft-committed singleton claim |
| Strong = 3 | Raft reservation plus acknowledged exclusions across a live-node snapshot |

The important distinction: writes/claims are coordinated, but ordinary lookups
are NOT linearizable reads. `global.Registry.Lookup` explicitly documents stale
reads. `global.Service.Lookup` reads local FSM first, then dissemination cache;
a non-member cold miss can forward a lookup to another member. That forwarded
lookup is not a quorum read barrier either. Lua returns a PID, not consistency
metadata or a claim epoch. Do not call every `lookup` strongly consistent simply
because registration used Raft.

Composed lookup priority is global, then eventual, then local/parent. LOCAL and
EVENTUAL registrations participate in cross-scope checks and consult `NameReady`
when global strong exclusion support is wired. The leader-reachability monitor
closes the readiness gate after failures and re-runs the join barrier on recovery.
Inspect exactly which OPERATIONS honor that gate: the visible PID/global lookup
paths do not become quorum reads or automatically reject all cached answers.

Raft's role is to agree on the authoritative ordered mutation/winner. Dissemination
propagates that decision to other nodes. An append-only distributed log without
leader/quorum/ordering semantics would not by itself solve concurrent ownership.
Conversely, an all-node acknowledgement barrier is stronger/different than a
quorum commit and is not required for every useful singleton claim.

### Strong protocol details requiring precise interpretation

`strong.go` opens a Pending reservation, with the leader stamping RequiredNodes
from its membership snapshot. The default deadline is 10 seconds. Each required
node checks conflicting LOCAL/EVENTUAL bindings and latches an exclusion before
ACK; conflicts can NACK. `CmdRegisterAck` is itself applied through Raft, and the
final required ACK promotes the reservation in the same FSM Apply.

`CmdDropRequired` allows membership departure to shrink that required set and
activate using the remaining ACKs. New/rejoining nodes have an epoch barrier and
conflict-revocation path. This is NOT proof that every physical machine, including
partitioned or sleeping hosts, currently resolves the new PID. It is a protocol
over a membership-defined set plus rejoin discipline. Also distinguish seeing a
Pending exclusion from observing the final Active mapping.

The required set includes membership nodes; it is not filtered to Raft voters.
Thus a non-Raft desktop client can still contribute to Strong registration work
and latency. With ~100 live nodes this can mean roughly one logged ACK per node
per Strong claim, plus reservation and dissemination. Do not publish a throughput
number without measuring it. Duplicated ACK log-work/coalescing deserves review.

## Confirmed production issue: stale unregister can delete replacement

This is a confirmed operation-composition defect, not a claim that Raft violates
consensus.

- Lua `registryUnregister` checks permission, then calls `globalReg.Lookup` and
  verifies the returned PID equals `self` (`module.go`, approximately 848–860).
- It then calls `UnregisterScope(name, mode)` with NO expected PID or epoch.
- `global/service.go` builds `CmdUnregister{Name: name}` or
  `CmdRegisterUnreserve{Name: name}`. No holder predicate reaches the state machine.
- `fsm.go` removes the active entry by name.

Possible sequence:
1. A's unregister call observes A as owner.
2. Another operation removes A; B registers the same name.
3. A's delayed unregister arrives and deletes B.

Stale replica reads make this possible even without a narrow simultaneous race.
The higher-level ownership check does not protect the committed mutation.

A deterministic FSM regression was written and executed through Go's source
overlay mechanism. It FAILS with `stale unregister removed the replacement claim`.
It reproduces the command sequence emitted by the Lua/service code; it is not a
full Lua/network fault-injection test. Extend it to those layers when fixing.

Artifact:
`/home/wolfy-j/wippy/bee/runtime/research/unregister_aba_test.go`
Overlay JSON already generated:
`/tmp/bee-naming-overlay.json`
Log:
`/tmp/bee-naming-aba.log`

Run from the runtime checkout:

```sh
GOWORK=off go test -overlay /tmp/bee-naming-overlay.json ./system/topology/namereg/global -run TestResearchUnregisterMustNotDeleteReplacement -count=1
```

The overlay maps a virtual added file
`system/topology/namereg/global/bee_research_test.go` to the Bee artifact and uses
existing test helpers `makePID`/`applyAt`. No runtime source was modified to run it.

Recommended fix direction: compare-and-delete at the state-machine boundary with
expected owner AND claim incarnation/epoch where necessary. Preserve an explicitly
authorized administrative unconditional deletion path if needed. Audit Consistent
and Strong active/pending removal, retries, wire compatibility and same-PID ABA.
Do not merely make the preceding lookup fresher; that leaves a check/use race.

### Additional high-priority source findings (no reproducer yet)

The parallel source reviewer identified two further gaps; parent inspected the
cited paths and confirmed the code shape. Neither has an executed regression yet.
Treat them as high-priority investigations, distinct from the reproduced ABA.

1. **Join snapshot is not captured at the claimed single index.**
   `join_barrier.go:77`, `buildJoinSnapshot`, samples `raftSvc.CommitIndex()` then
   independently calls `listPending()`, `listActiveStrong()`, and appends Consistent
   entries. Commit index can lead applied state, and these reads are not one
   atomic snapshot. The preceding comment claims a linearized/torn-free snapshot.
   A new pending admission or promotion during the reads can produce a mixed set
   that does not correspond to `StrongIndex`. Prove the effect on readiness and
   exclusion with a delayed-apply/interleaving test. Consider a state-owned snapshot
   carrying an applied index, and the necessary barrier, rather than sampling a
   Raft commit index beside unrelated reads.

2. **Cross-scope check/latch is not mutually exclusive with local registration.**
   `strong.go:327` explicitly describes separate locks and a residual race.
   `PIDRegistry.Register` checks `IsStrongReserved` then later uses `LoadOrStore`
   (roughly lines 127 and 158). Strong's `reserveCheckAndLatch` holds `reserveMu`,
   checks local non-presence, then records the exclusion. Both sides can observe
   absence before either commits. This is not solved by Raft serialization because
   the LOCAL write is outside the FSM. Review EVENTUAL's corresponding path too.
   If Strong promises cross-scope exclusion, use one local arbitration boundary
   or otherwise prove atomic reservation across both paths. It is not sufficient
   to label the window "inherent to AP/CP" and retain a strict exclusion claim.

### Related issues to verify, not yet fixed

- Go registration exposes an Epoch/FenceToken, but Lua currently discards the
  successful outcome and returns true. Naming claims alone do not fence a stale
  process's database/external side effects. Decide how callers obtain and enforce
  a token if they use names for exclusive execution.
- In `fsm.applyRegister`, a deduped registration returns the CURRENT log index,
  while the API comment calls Consistent Epoch the establishing first-write index.
  Check the intended receipt/fencing semantics before deciding this is a bug.
- Registration cancellation/timeout may leave an outcome that later commits.
  Provide reconciliation semantics; do not promise timeout means no claim exists.
- Audit watcher correlation, failover recovery and memory bounds for many pending
  Strong claims. Existing tests passing is not proof of every interleaving.

## Cluster roles, topology, trust and idle cost

`cluster.enabled` defaults false in boot. Bee's current `.wippy.yaml` has no
cluster activation. Named profiles already exist via
`cmd/internal/bootconfig/profiles.go`: ordered profile overlays and variable
resolution; an unknown profile errors. A future Bee profile UX should reuse this.

`cluster.raft.role=client` or `cluster.raft.enabled=false` disables the local
Raft node. Such nodes advertise `raft_eligible=false`. Clients still join gossip
and internode networking; they are NOT zero-overhead thin clients. Non-voter
standbys differ: they receive logs without voting. Defaults in boot select up to
5 voters and 4 standbys; verify actual deployed settings before changing them.

`internode.Service.Start` manages/connects pre-existing peers; join events add
connections to newly discovered peers. The topology is a direct peer mesh, not
an automatic star. At 100 nodes there are up to 4,950 unordered peer pairs. This
is a structural scaling observation, NOT a measured count of established TCP
connections; inspect dial arbitration and connection state before reporting one.
A gateway/relay-client mode for many transient desktops would be additional work.
Home-LAN reachability simplifies NAT issues, but does not remove these costs.

Inspected defaults:
- Membership gossip 500 ms; push/pull 5 s; dead-name reclaim 30 s.
- Raft heartbeat/election 3 s; commit propagation 500 ms.
- Strong deadline 10 s.
- Name leader probes 3 s, grace 3 failed probes, ping timeout 2 s. Do not infer a
  single exact outage-detection time without considering LastContact and RPC waits.
- TTY mounts lease 30 s, renew about every 10 s.

Membership has a shared-secret facility. Internode config requires HMAC/Ed25519
identity authentication, expected node-ID/trusted-key checks; handshake timeout
5 s. TLS defaults disabled. Authentication is not equivalent to confidentiality.
Review profile trust/encryption settings for the real LAN and the actual API
client threat model; do not turn off auth merely to make onboarding easy.

## Bee remote-view feasibility: established and missing

Runtime supports remote recipient-bound TTY mounts with independent Observe,
Input and Resize rights. Local/remote views expose cached snapshots and coalesced
updates. Requests are bounded, cancellable and protected against transport replay.
The transport verifies the peer; a mount record selects the surface, not arbitrary
payload fields. A new process/reconnection needs fresh authority. Mounted views
cannot redelegate. One producer can have several observers.

One native PTY still has ONE geometry. Independent client window sizes cannot all
resize it concurrently without a controller policy. Bee should initially give one
attachment input/resize control, with other observers clipping/letterboxing the
same content, or have an app explicitly supply independent views. Mesh membership
alone must not grant view access.

`system/process/manager.go:Start` selects a host on the local relay node. Remote
app launch therefore needs an authorized request to an owner/broker on the target
node. Don't pass a remote node ID as if ordinary Lua spawn were remote placement.
The producer viewport must be owned in the appropriate runtime; send mounts, not
Go objects/local producer grants, to the client.

The current Bee presenter directly calls `view:send` and `view:resize` in its
input/render loop. Before enabling remote attachments, move network-waiting work
into bounded asynchronous workers and make failure/overflow visible. A stalled
remote peer cannot be allowed to block local exit or tab navigation.

Current Bee assumes one session/workspace; it does NOT yet have a durable workspace
ID carried by all tabs or client-owned attachment layouts. Workspace/tab identity,
layout grouping, remote launch admission and controller transfer are Bee work.
Do not add those product concepts to #653. Runtime changes need a demonstrated
missing primitive or failed invariant from a two-client acceptance proof.

## Registry overlays are not cluster replication

`system/registry/overlay.go` implements process-local owner/generation-scoped live
changes, without advancing durable history. It rejects collisions with durable IDs,
cross-owner dependencies and directive-owned kinds. It does not replicate to peers.
`LoadState` clears process-local overlays, as covered by tests.

Raft global naming and the multiplexed KV FSM are separate from application entry
registry/history. They do not automatically replicate app definitions or SQL files.
Bee can later put small manifest/ownership/activation records in replicated KV,
distribute immutable source/package revisions separately, then materialize locally
accepted entries. Each node needs a receipt and conflict/recovery policy. Sharing
an overlay means distributing saved source/intended revision, not sharing handles.
Do not promise an atomic multi-node update across registry, files and migrations.

A logical workspace can span nodes while each durable resource/thread initially
has one authoritative owner. Owner failover requires fencing and a consistency
policy. Replicated configuration is not replicated filesystem or process state.

## Tests executed and exact evidentiary limits

All commands below used the inspected runtime checkout with `GOWORK=off`. Without
that override an unrelated ambient go.work rejects the module. Do not alter the
user's Go workspace to fix this. Go/socket tests needed sandbox escalation.

1. Mesh/overlay/internode subset, PASSED:

```sh
GOWORK=off go test ./system/tty ./cluster/internode ./system/registry -run 'Test(Mesh|Remote|Stalled|SupervisedMount|Integration_TwoNodeCommunication|Integration_ThreeNodeCluster|.*Overlay)' -count=1
```

Log `/tmp/bee-cluster-research-tests.log`.
TTY mesh tests use controlled in-memory peers; internode tests exercise local TCP.
Includes remote snapshots/input/replay, invalid peer, cancellation/lease handling,
stalled peer independence, and overlay ownership/history/generation cases.

2. Replicated KV/client/failure subset, PASSED:

```sh
GOWORK=off go test ./cluster/clustertest -run 'TestE2E_(KVReplicatesFromFollower|LeaderFailover|PartitionHeal|DurableRestart|KVRegistry_ClientResolves)$' -count=1
```

Log `/tmp/bee-cluster-kv-tests.log` (about 10 seconds). This harness is not a
100-node physical LAN test or a multi-Bee desktop test.

3. Profile loader, PASSED:
`GOWORK=off go test ./cmd/internal/bootconfig -count=1`
Log `/tmp/bee-profile-tests.log`.

4. Full naming/topology packages, PASSED:
`GOWORK=off go test ./system/topology/namereg/global ./system/topology/namereg/eventual ./system/topology -count=1`
Log `/tmp/bee-naming-review-tests.log`.

5. New stale-unregister research regression, FAILED as expected (confirmed gap).
See reproduction above. No corrective implementation has been made.

No 100-node benchmark, claim linearizability checker, LAN traffic measurement or
full two-Bee/two-client test has been performed. Do not turn the passing unit and
integration subsets into a blanket production-readiness statement.

## Recommended review sequence

1. Write the exact contract for claim uniqueness, lookup freshness, all-participant
   exclusion and side-effect fencing. Distinguish Local/Eventual/Consistent/Strong
   without treating their names as proofs. Confirm what the user actually needs
   to block during a partition: new owner assignment, discovery, or all work.
2. Fix and test atomic unregister ownership/incarnation. Review timeout/retry
   receipts and expose fencing where it is a real application requirement.
3. Keep a small stable Raft group for authoritative cluster claims initially.
   Ordinary discovery remains cached/eventual. Reserve the all-participant Strong
   barrier for actual cross-scope exclusion needs, not every agent/tab/resource.
4. Evaluate whether cross-scope collision semantics justify involving all transient
   clients. Any participant-set optimization must prevent excluded clients from
   minting conflicting names; filtering them from ACKs alone is unsafe.
5. Benchmark 3/5 voters with 10/30/100 total nodes, stable and churny clients.
   Measure claim latency p50/p95/p99, ACK/log amplification, connection count,
   bytes/sec idle and under churn, CPU/memory, snapshot/catch-up costs, and recovery.
6. Fault-test asymmetric partitions, stale readers, late unregister, same-PID
   reclaims, node restarts, duplicate messages, delayed ACK/NACK, leader changes
   mid-Strong claim, and canceled requests that may have committed.
7. Return a recommendation with measured tradeoffs and a small patch set. Do not
   replace consensus with a homemade distributed log or build a new control plane
   before showing which property the existing design cannot meet.

Provisional judgment from the Bee agent: Raft is appropriate for a bounded
claim/ownership control plane. The all-node barrier, read-contract ambiguity,
atomic mutation checks and mesh scaling deserve scrutiny before Raft itself is
removed. A single authoritative server is an alternative only if single-host
availability is acceptable; failover of that authority reintroduces coordination.
