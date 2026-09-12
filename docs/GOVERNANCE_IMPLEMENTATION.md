# Bee governance implementation plan

Status: source now includes private, host-admitted authoring workspaces. Overlay
activation, Hub resolution or installation, approval consumption, and Hive
replication remain unimplemented.

Bee owns a small governance subsystem. It has no Keeper, Kickside, web view,
or language-model dependency. The first publication acceptance target remains a
headless install and update of a private Hub component, including its migrations.
The existing
`wolfy-j/bee-registry-planner` package only plans harness activation and stores
candidates; it does not satisfy this target.

The current authoring seam is `bee.governance:workspace_call` through its local
contract: create, list, read, put, remove and freeze caller-owned virtual files.
Writes use an expected revision plus a stable idempotency key; freeze retains a
measured copy and does not publish or execute it. The protected function checks
the authenticated actor and a host-supplied read or write operation on the exact
workspace ID. No default authoring operation policy is installed.
The ordinary application boundary still denies direct governance-store access;
on the current runtime that deny also applies when an ordinary app calls the
store-backed function. The source therefore does not yet expose authoring to a
bundled app. A host may admit a separately scoped external actor while a future
dedicated owner/process boundary is designed and accepted.

## Decision and ownership

User approval is the default. The approval names the exact resolved candidate,
including dependency artifacts, parameter bindings, migration bodies and effects.
An agent can request a change and inspect its outcome; installing its trait does
not let it approve the request or publish registry entries.

Reuse the existing Bee approval owner for human decisions. A host-selected
decision contract permits a later separately installed policy/checking module.
Package metadata cannot select that contract or expand the host's authority.
Model-based checking and automatic policy decisions are later adapters, not
dependencies of the initial subsystem.

The governance owner alone executes admitted changes. The runtime continues to
own dependency expansion, linking, registry history and resource lifecycle.
Governance must not create another registry or dependency reconciler. Protected
core changes remain maintenance operations.

## First slice

1. Resolve an exact Hub request against a pinned registry state. Record every
   selected version and verified artifact digest, requirement binding, changed
   entry, migration and lifecycle effect. Refuse missing bindings, collisions,
   changed applied migrations and changes outside host policy.
2. Persist the candidate before requesting approval. Bind the approval to its
   canonical digest. Edits or a stale base require a new candidate and decision.
3. After approval, recheck the base, policy and artifact closure, consume the
   decision under one durable operation identity, and apply through the runtime.
4. Reconcile the committed definitions from a fresh execution context. Run only
   the admitted pending migrations, then verify their ledger and installed
   closure. A pre-commit view finding zero migrations is never proof of success.
5. Persist a receipt with separate publication and migration outcomes. Resume
   after interruption by inspecting those outcomes; never blindly repeat an
   uncertain publication or report an incomplete migration as a successful
   installation. Do not claim migration rollback reverses arbitrary effects.

The agent trait delegates to this owner: propose, status and resume are the
initial operations. Approval remains a separate user operation. No physical
terminal is needed to carry the workflow from a committed decision to its receipt.

## Waiting, callbacks and distributed inbox

Use the reusable wait/wakeup contract already specified in
[approvals](APPROVALS.md#required-reusable-wait-and-wakeup-contract). Persist the
operation, exact candidate and admitted continuation before requesting approval.
A temporary process holds a bounded worker lease and attempt epoch; durable
operation identity is independent of that process and its PID. Register the wait
and recheck the approval owner so a decision during registration cannot be lost.

The inbox submits a decision to the approval owner. After that owner commits,
delivery wakes the governance owner through a host-admitted typed continuation.
The callback is a wake hint with stable correlation and event identity; the
governance owner reads the committed decision, rechecks its candidate and consumes
the approval before executing. A stale worker epoch cannot continue. A crashed
worker is replaced from durable state, and an uncertain already-dispatched effect
is reconciled before retry. Closing the inbox or disconnecting a client does not
cancel the operation. No requester-supplied executable callback is accepted.

Each destination node remains authoritative for its own approval and operation
records. A combined inbox tracks a separate cursor for each admitted owner and
keys items by owner node, workspace and approval identity. Both direct access and
access through a client use the same authenticated owner operations; a connected
transport peer is not by itself an authorized human approver. There is no global
decision sequence or shared cross-node SQL transaction. Disconnected owners are
shown as unavailable, with pending answers explicitly unconfirmed until the owner
acknowledges or reconciliation returns its committed decision.

The existing `bee.inbox:app` is a local themed list/detail view with explicit
actions. Its current function calls target the local approval owner. Federated
inbox routing, the reusable continuation dispatcher and modular presentation
adapters remain unimplemented. Extend that inbox through admitted presentation
contracts with a built-in fallback, rather than creating a governance-only inbox.
Present the operation, destination, dependency/migration summary and decision
state first; keep digests and execution diagnostics available in details. Any
optional renderer remains presentation-only and cannot issue its own grants.

A temporary worker lease serializes this workflow's workers. It does not make
the runtime's durable registry apply atomic against other registry writers;
the publication precondition gate below remains required.

## Runtime gates to establish before publication

- The executable under test must expose the same verified artifact and registry
  APIs as the selected runtime source; source documentation alone is insufficient.
- Candidate preview must describe the expansion that publication will actually
  apply. Checking only the requested `ns.dependency` is insufficient.
- The publication boundary must serialize owner writes and enforce the expected
  base. A Lua read immediately before an unconstrained apply does not provide
  compare-and-set against another writer.
- Resource activation and migration ordering must be explicit. A package that
  starts a service requiring an unapplied schema needs a supported readiness
  barrier or must be refused by this first slice.

`make governance-runtime-check` now reproduces the durable-publication gap in
an isolated four-entry composition with stdin closed. On the development
toolchain (runtime `055505e`), a candidate from v0 still commits as v2 after an
intervening v1 write. The fixture lints successfully, but the guarded-publication
gate fails with `GOVERNANCE_STALE_APPLY_ACCEPTED`. The selected runtime source
at `674b58a` also calls ordinary `Apply` without the snapshot version. This is
source evidence for that newer revision, not an executable test of its binary.
The gate is separate from `make check` while this runtime contract is missing.

The September 11 candidate at runtime `291f5c6b708c80afe5da07f3223767573b4d183f`
reproduces the same failure with the unchanged executable gate: lint passes,
then a candidate reviewed at v0 commits as v2 after an intervening v1 write.
This is current executable evidence; guarded publication remains unavailable.

## Acceptance

Use an isolated headless Bee composition with no Keeper or view packages.
Publish immutable private fixture versions under `wolfy-j`; install the first
through the trait/owner route, approve as a distinct user principal, and verify
its migration and functional result. Update through the same route, preserving
the original database and records, and verify the appended migration. No manual
migration invocation is permitted between either request and its receipt.

Also prove denial, agent self-approval refusal, stale candidates, unresolved
requirements, artifact drift, concurrent requests, migration failure and retry,
and restart after publication before receipt. Inspect background service failures
as well as the final result. Keep the binary/Hive lane's files and running checks
under their existing owner.

Distributed acceptance additionally needs two actual nodes, two eligible viewers
racing the same request, both direct and client-routed access, disconnected-owner
status, lost decision acknowledgements, reconnect catch-up, revoked approver
authority and a worker takeover rejecting the old lease epoch. This evidence is
separate from the existing local inbox and local approval-owner tests.

## Following slices

Overlay candidates use the same validation, approval and receipt contracts.
Their adapter adds durable desired state and cold-start reconstruction because
runtime overlays are ephemeral. Hub installation does not establish this proof.
Harness/model support and self-modification follow those foundations, with
protected authority changes still requiring maintenance approval.
