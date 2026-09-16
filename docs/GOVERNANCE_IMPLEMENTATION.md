# Bee governance implementation plan

Status: source authoring, immutable transfer-candidate identity, exact resolved
registry artifact encoding, Hive replica transfer and the internal destination plan
store, activation ledger and overlay materializer are implemented; public installation, activation and plugin dispatch remain
unimplemented. See
[distributed delivery](DISTRIBUTED_APP_DELIVERY.md) for the staged destination-owned flow.

The internal `bee.governance:preflight` library now checks a host-resolved closure
for destination/base mismatch, package/namespace/kind policy, exact package-owned
child namespaces and conflicts with existing namespace owners, requested grants and
runtime modules, missing dependency
members, final-state references, typed requirement bindings, ownership collisions,
applied migration changes/removal, migration database admission and unsafe early
service activation. Its deterministic report contains bounded diagnostics and
remediation instructions, pending migration identities and a digest binding the
candidate, host policy and applied-migration baseline. It has no write capability.
`make governance-preflight-check` exercises this slice. There is no production
resolver adapter, installer, activation trait or worker yet; the context supplied
to this internal library must never be accepted as authority from a remote peer.

`bee.governance:activation_measure` now turns a host-resolved candidate and
current context into exact local execution evidence. It requires an accepted
selected plan, byte-for-byte artifact entry measurements, a ready fresh
preflight, no pending migrations and no dependency directive in the overlay.
The host resolver that supplies those facts still needs to be wired to Hub.

The pure `bee.governance:artifact` library copies, sorts and canonically encodes
the complete resolved registry definitions needed for a later overlay apply. Its
bounded byte form carries a schema and SHA-256 digest; byte-only receivers decode,
remeasure and require canonical equality before accepting the entries. It reads no
registry, grants nothing and has no apply operation. This keeps resolution and
activation as separate destination-authorized steps.

The destination-local `bee.governance:plan_store` persists source-qualified
available versions separately from the workspace's selected version. Its strict
lifecycle is stage, accepted/rejected review, explicit selection and binding to a
local approval request. The plan digest covers the destination identity and all
candidate, artifact and preflight digests. Approval binding retains that plan
digest separately from the Approvals owner's canonical proposal digest, so the
effect owner can both prove what was reviewed and consume the exact approval.
CAS revisions and bounded retry
receipts survive database reopen. This internal store does not request or consume
approval, expose a public method, read the registry or apply an overlay yet.
`bee.governance:destination.stage_replica` is the internal bridge into this store:
the caller supplies only a complete local replica identity and idempotency key.
The bridge rechecks the available replica's descriptor and bytes, decodes the
canonical application-version envelope, requires its frozen candidate to name the
opened destination node/workspace, and constructs the revision-zero stage request
itself. A transferred source preflight report is retained as review evidence; its
`ready` field grants no destination authority and cannot skip the later local check.

The internal `bee.governance:workspace` helper also freezes bounded trusted file
records using per-file content hashes and a deterministic manifest, binding the
workspace identity and revision. It rejects ambiguous/escaping paths, duplicate
and file/directory collisions and quota overruns. Binary bytes are measured
directly, not encoded into JSON. The focused suite passes 16 checks covering both
helpers; the helper does not implement file serving, authentication or durable
staging. Returned records are copied but remain mutable Lua values: an executor
must verify the content against the admitted measurement again.

The source authoring owner now exposes create/list/read/put/remove/freeze through
`bee.governance:workspace_call`, a contract binding and an authoring-only agent
trait. Host-selected read/write operation permissions are scoped to workspace ID,
and the authenticated actor must also match its stored owner. A checked SQLite
migration owns mutable files, frozen copies and bounded retry receipts. Writes
use expected revisions; identical retries return committed receipts across
restart. Freeze retains a separate binary-safe copy without activating it.
See [the module contract](../src/governance/README.md) for request fields and
capacity limits. Managed Agent host policies now admit this facade through the
private MCP gateway. Storage still enforces actor ownership, and the scope has
no host filesystem mounts, registry writer, publication, approval or activation
rights.

Authored entries use the native registry envelope: `id`, `kind`, optional `meta`,
and required object `data`. Source, modules, security and lifecycle configuration
belong inside `data`. Flat YAML shorthand and registry ownership provenance are
rejected before staging. Preflight reads capabilities from that same native
configuration, preserving the destination's host-selected ceilings.

An authored application snapshot contains `entries.json`, a plain JSON list of
complete registry entries. Preparation parses that frozen file and creates the
canonical measured artifact with `bee.governance:artifact`; it executes no code
and does not mutate the snapshot. This removes the need for an Agent to produce
the internal canonical artifact envelope itself.

`make governance-workspace-check` passes actual authenticated function calls over
two boots of the same database, including concurrent revision contention, binary
round trips, cross-author refusal, replay after restart, frozen copies surviving
edits/removal and explicit snapshot-capacity refusal. The whole-tree validation
and receipt commit share the edit transaction. This is local source acceptance,
not installed-global or Hive activation evidence.

Keeper study: its canonical Hub planner resolves the entire bounded constraint
graph, not just the requested dependency; full-ID requirement bindings are not
silently forwarded to transitive modules. Its install precheck overlays changes
on the final registry and rejects missing contract/requirement targets. The
migration fix invalidates cached ownership after publication and discovers named
pending migrations in a fresh context. Bee retains these requirements without
importing Keeper, its agents, views, migration bootloader or permission scope.
Remediation produces a new candidate; no suggested fix mutates an approved plan.

Bee owns a small governance subsystem. It has no Keeper, Kickside, web view,
or language-model dependency. The first acceptance target is a headless install
and update of a private Hub component, including its migrations. The existing
`wolfy-j/bee-registry-planner` package only plans harness activation and stores
candidates; it does not satisfy this target.

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

### Sole writer and extension boundary

Governance is the sole agent/application-facing mutation authority for both
durable registry state and ephemeral overlays. Workspace files, trait installation,
plugin registration and inbox participation confer no raw registry or overlay
writer capability. Trusted runtime/core readers retain the lookup permissions
needed to run Bee. Native OS-user shells are not sandboxed by this Lua boundary;
host maintenance and boot authority must remain explicit exceptions, not hidden
agent tool paths.

Governance must support host-admitted plugins through versioned typed contracts:
precheck validators, policy-review adapters, lifecycle observers/hooks and inbox
interceptors. Admission pins plugin identity/version and the allowed phases and
capabilities; package metadata cannot select its own approver or interceptor.
This extension surface is planned, not implemented or callable yet.

Precheck plugins return bounded diagnostics, refusal or proposed repairs. Repairs
create a new candidate and invalidate the old approval. Policy modules use the
separate host-selected decision contract; human approval remains the default.
Lifecycle hooks declare any effects and authority in advance, never inherit the
governance writer, and report pending/failed/uncertain outcomes separately from
successful activation. Hook ordering, required/optional status and exact plugin
versions are measured into the plan. Required checker timeout/failure blocks the
operation; advisory failures remain visible. No blind retry of uncertain effects.

Inbox interceptors may enrich or route an authorized projection and propose a
review/escalation, without rewriting candidate identity, destination, committed
decision or approval eligibility. Required user approval cannot be silently
suppressed or synthesized by an interceptor. Preserve a built-in presentation
fallback, owner-qualified correlation and deduplicated delivery. Interception
does not bypass audience checks or forward private data to an unadmitted node.
Every invocation is bounded by timeout/output limits and recorded with its plugin
identity and outcome in the operation ledger. Changing an admission or decision
plugin invalidates affected pending plans before execution.

## First slice

### Primary activation mode: service-owned overlays

Most internal applications enter governance as immutable packs or explicit
changes. The primary execution target is an ephemeral, service-owned runtime
overlay, not a durable registry publication. Definitions participate in composed
runtime lookup, but are not written to durable registry history. The owner holds
the overlay handle and generation, controls its lifetime, and reports cleanup
failure rather than pretending the application was removed. Persisted operation
and approval receipts do not imply persisted definitions or automatic reactivation.
Cold-start restoration is an explicit later policy, not the default.

`make governance-overlay-check` proves the executable's owner-local boundary:
create/update/delete leave durable history unchanged; stale owner generations,
foreign ownership collisions, unadmitted owners/entry namespaces and durable
publication attempts are refused. Cleanup is explicit. The runtime owner ID is
logical, not a PID: process exit does not automatically revoke its definitions.
This fixture does not prove composed-base fencing, dependency expansion, service
readiness or migration ordering. Runtime overlay directives are a separate limit:
the inspected source rejects directive-owned kinds, so raw Hub dependency entries
cannot simply be submitted as overlay content.

The internal `bee.governance:materializer` now performs complete desired-set
replacement for one caller-selected logical overlay. It remeasures and copies
the artifact, creates, updates and removes exact owner entries, and treats one
native overlay generation as its write CAS. A conflict returns without retry so
the destination owner must rebuild context and rerun preflight before another
attempt. The destination owner still has to consume approval before invoking it
and reconstruct the selected overlay on boot.

Agents require a host-admitted headless execution environment with typed
governance operations, destination identity, bounded staging access and scoped
status/receipt access. The environment must not expose raw overlay/registry
writers, host credentials or authority to approve its own requests. The service
resolves and measures content in its trusted destination context; an agent cannot
supply policy flags or claim that a package passed validation. Approval waiting
and continuation work without a keyboard or a live client. The governance trait
delegates to this owner rather than granting the caller its permissions.

### Agent authoring environment

The agent interface must support a complete bounded application workspace, not
just submission of registry RPCs. A host-admitted workspace exposes convenient
file listing, reading, writing, patches and diagnostics, with explicit resource
identity, revision and quotas. Files can describe services, child namespaces,
requirements/bindings, migration definitions and WASM assets. Child namespaces
belong to the measured package closure; nesting does not bypass ownership,
collision or host-policy checks. These are planned capabilities, not callable
operations today.

WASM filesystem access uses explicit host-selected virtual/preopened roots and
read/write rights; a package cannot authorize host paths by declaring them.
Separate writable authoring files, immutable resolved dependency/artifact inputs,
and admitted runtime application data. The filesystem adapter must enforce
containment, including traversal and symlink escapes, and bound storage and I/O.
Neither Hive transfer nor a workspace descriptor carries host credentials or
implicitly mounts the source node's directories on a destination.

The intended workflow is edit, inspect/validate, test in an admitted isolated
environment, freeze an immutable candidate, request approval, then activate or
update and inspect service/migration outcomes. The service must execute the
measured frozen content, never mutable workspace files changed after approval.
Service declarations include dependencies and lifecycle/readiness effects;
dependent services cannot start before their approved migrations complete.
Migration bodies and named database bindings are part of the reviewed closure,
with persistent checksum ledgers and unchanged applied migrations on update.
Testing receives its own bounded authority and disposable stores; it does not
implicitly gain production data access or permission to run arbitrary host code.
The trait exposes structured errors, precheck remedies, operation status and
scoped logs so agents can iterate without a keyboard. Repairs produce a new
candidate and approval. Public operation names and the concrete WASM filesystem
adapter remain to be established against available runtime capabilities.

The executable `make governance-wasm-check` currently fails its containment
gate: a read-only `fs.directory` WASI mount permits reading a synthetic outside
file through an absolute symlink inside the mount. Admitted reading succeeds,
while writable-open and parent-traversal probes are refused. This is a real guest
execution using a self-contained MIT WAT fixture, not a source-only inference.
Do not admit host-directory WASM mounts to untrusted agent executions on this
evidence. Runtime containment must be fixed and the unchanged negative test must
pass before enabling that adapter. Lexical authoring-path checks cannot repair
runtime symlink resolution. The focused gate stays separate from the foundation
suite while red.

Overlay activation and update need their own acceptance: exact expanded content,
owner/generation fencing, immediate owner-local re-preflight, migration ordering,
replacement, and owner-exit cleanup. The owner may retry only after an overlay
generation conflict and another preflight. The failing durable-publication probe
below does not block this distinct adapter.
Ephemeral definitions do not make database effects ephemeral: migrations still
use persistent append-only ledgers, including on update, and overlay removal
does not roll back application data. Durable registry installation is a separate
explicit mode, subject to the durable-publication gate below.

The following sequence describes the shared planning/approval lifecycle; its
publication step must use the selected overlay or durable adapter, never silently
fall back between them. These adapters and the agent environment are not yet
implemented.

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

The existing `bee.inbox:app` now supports explicitly configured local and remote
approval owners through the typed feed protocol; see [sync and inbox](SYNC_AND_INBOX.md).
The reusable continuation dispatcher and modular presentation adapters remain
unimplemented. Extend that inbox through admitted presentation
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

Rechecked against the combined candidate executable on September 10: the same
v0/v1/v2 stale-apply acceptance is reproduced. An application worker lease or a
fresh Lua read cannot repair this race against another registry writer. The
runtime lane must provide atomic expected-version publication and an exact
expanded-closure preview before this governance owner gains publication authority.

## Hive package and overlay sharing

Reuse the sync subsystem for authorized descriptions and desired-content
references, with immutable artifact/overlay digests and source/owner-qualified
identities. Content transfer must verify the received bytes against those digests;
the sync ledger is not an unbounded binary attachment transport. A source node's
approval, execution receipt or capabilities do not authorize a destination.
Each destination resolves the shared content against its own base, bindings,
host policy and migration ledgers, then requests its own approval. Shared repairs
or updates produce new digests and new destination plans. Offline destinations
may retain descriptions, but cannot claim installation or successful migration.
No source credentials, worker leases, process IDs or private host paths belong
in a shared package/overlay description. This transport adapter is still proposed.

## Native runtime handoff

Required before the install/update owner can use durable registry publication:

The following handoff applies to the optional durable registry publication
adapter; it is not a prerequisite for owner-local overlay activation:

1. A durable changeset operation that carries the expected base and compares it
   under the same registry writer serialization as publication. Refuse an old
   base before preparing resource effects or history changes. Governance must
   never fall back to an unguarded operation.
2. A bounded preview of complete expanded changes and resolved immutable
   artifacts, including requirement substitutions and removals. Execution must
   consume or revalidate that exact closure, with no fresh unconstrained
   resolution after approval. Include overlays in the relevant registry-state
   precondition for durable publication: a durable version alone does not detect
   overlay changes.
3. A post-publication fresh-context/readiness contract so the owner can discover
   only the approved migrations before enabling services requiring their schema.

Acceptance must race a competing durable writer and an overlay change against a
reviewed plan, and assert rejection without history or resource effects. A Lua
check followed by ordinary `Apply` is insufficient. The existing isolated
`governance-runtime-check` reproduces the missing durable-base guarantee; extend
it for the exact guarded capability the runtime exposes.

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
Optional durable desired state and cold-start reconstruction are separate from
the default service-owned ephemeral lifetime. Hub installation does not establish
overlay acceptance.
Harness/model support and self-modification follow those foundations, with
protected authority changes still requiring maintenance approval.
