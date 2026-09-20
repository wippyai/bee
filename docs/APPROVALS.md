# Durable approval requests

The owner is built as `bee.approvals` (see `src/approvals/README.md`). The
typed owner-feed and inbox integration are described in
[sync and inbox](SYNC_AND_INBOX.md), including their explicit enrollment limits.
Existing application dialogs are live broker-owned
questions, not durable authorization records. Do not treat their confirmation
messages as grants for remote operations. The first proposed use is approval of
a remote Terminal request through the destination supervisor.

## Ownership

The destination operation owner determines whether approval is required and
which principals can answer. A local approval service owns durable records in
an owner-scoped database on that node. Workspace requests belong to the target
workspace; machine enrollment requests belong to the machine's authority and
must not depend on an arbitrary project being open. The exact database binding
is selected by the host. No central SQL catalog is introduced.

Clients subscribe to eligible records across reachable owners and present a
combined inbox. This is a projection, not replicated decision authority. A
shell may show a dialog, a standalone inbox application or another presentation;
the owner accepts the decision through the same typed operation. A headless owner
can retain a pending request without any connected client.

The authenticated transport peer identifies a node, not automatically a human.
The supervisor must establish the requesting session's principal/delegation and
an approval recipient's authority. A claimed user name or PID in a payload is
not enough. Mesh membership and possession of an inbox item confer no approval
rights. Reading request details may itself require permission.

## Durable record and transitions

An approval record contains an opaque request ID, owner/workspace identity,
contract and operation version, normalized action/resource parameters or their
owned durable reference, requester identity/delegation, approval audience,
creation and expiry times, revision, display description and current decision.
The displayed request and the authorized operation must refer to the same
immutable action revision. Editing parameters requires a new decision.

Decision states are pending, approved, denied, expired and cancelled. Execution
has a separate state and result: approval is neither completion nor a promise
that the remote operation will succeed. Local deadlines are enforced by the
owner when committing a decision; the client countdown is informational.

A decision transaction checks the pending revision, deadline and authenticated
approver. It commits the selected decision and a durable delivery record together.
Concurrent answers cannot produce two accepted decisions. Repeated identical
requests return the committed result; conflicting answers return a conflict.
Cancellation racing approval must return the actual committed outcome, not claim
the operation was prevented. After execution starts, stopping it is a separate
owner operation with its own outcome.

After an authority restart an effect owner presents the incarnation it
observed; the owner compares it with the current incarnation, and a decision
made under an earlier one must be revalidated by the effect owner under the
current incarnation, recorded on the request, before it can be consumed.
Comparing only against the incarnation stored with the request would not
fence stale authority.

Approvals bind exact scope. Reuse for a session or remembered policy is a separate
explicit choice that the owner validates. A general confirmation must not become
unbounded terminal or filesystem access. Authorization is rechecked before
execution, including revocation and owner/session incarnation where applicable.
Policy changes may invalidate unused approval; the caller receives that result.

For the bundled Native Terminal, the approved capability is native execution as
the destination OS user. Selecting a workspace or working directory does not
confine that shell to the workspace's files. The request description must reflect
this existing execution boundary. A confined terminal requires a separate
provider with an enforced isolation contract.

## Delivery and recovery

A transactionally recorded outbox drives decision delivery. Registered adapters
may post to a thread, send a process message or invoke an admitted contract.
Arbitrary executable callbacks, code strings and recipient addresses from an
untrusted requester are not activation authority.

Adapters use stable event/operation IDs and durable acknowledgements. Delivery
is at least once; receiving owners deduplicate effects where their operation
supports it. A send success is only queue acceptance. A lost execution result is
unknown until reconciled, never a reason to repeat a terminal launch blindly.
A stale process PID is not a durable callback target; resolve an authorized
logical owner on recovery and revalidate its current execution.

Persisted deadlines remain enforceable after restart. The owner schedules the
nearest expiry and reconciles on boot; dormant workspaces should not each need
an always-running polling actor. Offline nodes retain their records locally.
A disconnected inbox reports uncertainty rather than inferring approval, expiry
or deletion from missing updates.

## Proposed storage boundary

Implement this as an independent typed Lua subsystem, with an actor owner,
contract/consumer library and private persistence module. Reuse the checked
migration discipline in [storage](STORAGE.md) and the authenticated contract
boundary in [threads](THREADS.md). Do not turn the presenter, a thread subscriber
or a generic callback runner into the authorization owner. These are proposed
records, not applied migrations or callable APIs:

| Record | Purpose and constraints |
|---|---|
| Request | Owner-qualified request ID, authenticated requester, requester idempotency key, immutable normalized action/version, audience, deadline, decision and revision. Unique requester/key within the owner; different content under the same key is a conflict. |
| Decision receipt | Request ID, authenticated approver, expected revision, accepted decision, owner commit time and receipt ID. At most one terminal decision per request. Retrying a decision returns its receipt only after authorization is checked again. |
| Execution receipt | Stable operation ID and action reference, execution state, current executor incarnation and bounded result/error reference. Maintained by the operation owner, separate from the approval record. |
| Outbox delivery | Stable event ID, request revision, admitted logical destination/adapter version, bounded payload, attempt/lease information, next attempt and acknowledgement. Unique event/destination; retry preserves event identity. |
| Inbox change | Owner-local sequence, request ID and revision, sufficient for authorized paginated catch-up. Written with each request/decision change; never a global Hive sequence. |

The approval owner commits request changes, decision receipts, inbox changes
and outbox entries in its own transaction. Its migration ledger is private and
checked on open. Workspace-scoped records may use a host-selected workspace
resource; machine enrollment uses its own machine-scoped resource. Do not share
one global approvals database across workspaces or allow applications to select
an arbitrary database path. Sharing a physical file later does not permit
cross-owner table access or imply a cross-service transaction.

The execution receipt belongs to the service performing the operation. Across
stores or nodes, outbox delivery and a receiver-side receipt bridge the boundary;
there is no distributed SQL transaction. If execution cannot atomically record
its effect, it must reconcile or expose an unknown outcome after a crash.
Recording `started` before spawning a native process does not by itself close
that crash window. Remote Terminal must prove recovery of an existing instance
by stable operation identity before automatic launch retries are enabled.

Set explicit limits for pending requests per principal/owner, payload size,
outbox backlog and delivery attempts. A full queue returns a visible error;
it must not silently drop a decision or infer consent. Terminal delivery failure
remains visible and can be retried through an authorized operation. Retention
must preserve deduplication receipts for the advertised retry lifetime, and
compaction must return a reset-required cursor rather than skip unread changes.
Do not persist passwords, enrollment secrets or stream grants in display text
or inbox events.

## Inbox and trigger contract

The client keeps one cursor per owner and merges authorized projections for
display. There is no total order across nodes. Subscribe/wait notifications are
wake hints followed by `read_after` catch-up, so a missed notification cannot
lose a request. Reads and decisions recheck current audience membership; removal
of access clears cached details in the active UI without claiming that data
already disclosed can be recalled. Offline owners are shown as unavailable.

A trigger binds a versioned event to an admitted logical operation: for example,
`decision committed -> append thread event` or `execution changed -> notify
application`. Installation chooses the adapter and its allowed destination;
the incoming request cannot supply executable Lua or grant new authority to it.
Events retain causation and correlation IDs, and effects enforce deduplication
and bounded recursion/fan-out. An application may propose another action, which
enters the same authorization path rather than inheriting the earlier approval.

Keep informational questions distinct from authorization requests. Both can
use shared visual components, deadlines and typed responses; only a decision
accepted by the operation's authority can release an effect. User-editable inbox
views and notification rules must not edit grants or bypass this boundary.

The first implementation should support one exact action and one approval
recipient, with durable pending/decision/outbox recovery. Prove approved remote
Terminal admission through that path before adding remembered policies, arbitrary
trigger graphs or multi-approver rules. This keeps the initial UI small while
preserving the subsystem boundary for later in-app construction.

## Permission exchange

A harness asking permission mid-run is an exchange the profile must prove,
not a terminal outcome reinterpreted. Existing captures prove terminal
permission-denied results only; both shipped profiles stay
`permission_exchange: {mode: none}`. The pure rules live in
`bee.harness.permission:adapter`; nothing is wired to the carrier until a
captured, continuing exchange and the crash proofs below exist.

| Rule | Contract |
|---|---|
| Adapter | A `harness.permission_adapter` entry decoded under `bee.permission-adapter@2`: the request event name and revision, the request fields, the allow and deny response shape, the acknowledgment semantics (`correlation_echo` or `continued_output`), the cancellation behavior (`deny_before_close` or `unsupported`) and the proof fixture. The profile pins `adapter_ref` and `adapter_digest`; the catalog measures the adapter from the same pinned snapshot and marks a mismatch incompatible. |
| Identity | The permission request identity is the observation's event key, derived from the envelope position, so a replayed stream names the same request. The proposal is an `attempt` proposal binding the attempt plan digest as its revision, the action, the input digest and the adapter digest. The carrier epoch is execution fencing context and never part of the proposal; takeover does not change it. |
| Keys | Approval idempotency key, effect key and write id are each derived from owner, attempt and permission request identity. Harness correlation ids can repeat and are never a key on their own. |
| Intent first | Before asking, the carrier checkpoints a permission intent: provenance, proposal digest and the deterministic approval idempotency key. A crash between approval creation and checkpoint completion recovers by replaying that key. |
| Consume, then write | Consumption reserves the effect for the effect owner; it proves nothing about dispatch. The response goes out under one deterministic write id through the intended, accepted and uncertain write path. A consumption replay never resends. |
| Replacement | A replacement carrier recovers the existing approval and write from its checkpoint. It queries the surviving fenced runner before any first dispatch; lost runner evidence leaves an ambiguous write uncertain. |
| Identity conflicts | The same permission request identity with different permission content or adapter digest is `CONFLICT` at the owner, since both are inside the request digest. Two simultaneously pending requests with one harness correlation id are ambiguous to the response protocol; the second is refused, never merged. |
| Transcript consistency | `transcript_consistent` says only that a transcript shows the request, no terminal before the response position and an acknowledgment after it. It does not show that the response was written to the child or that the harness acted on it. |
| Interactive acceptance | A live fixture runner observes the request before sending the response, records the input-write boundary, verifies the adapter's correlated acknowledgment after it, and exercises allow, deny, wrong correlation and no response (`tests/lua/harness/acceptance_test.lua`). The catalog reports eligibility (a pinned, measured adapter) apart from compatibility; a `proof_fixture` name authorizes nothing. Host admission requires a `harness.permission_acceptance` record binding the driver binding digest, profile digest, adapter digest, fixture digest and proof revision; any changed measurement needs renewed acceptance. Registry-supplied fixtures are never executed during discovery or ordinary admission. |
| Executable measurement | The acceptance record carries `executable_revision`, `executable_kind` and `executable_digest`: placement's measurement of the executable the exchange was proven with, and what that digest covers (`elf` covers the native image; `script` covers the script file, never its interpreter; `other` covers bytes of no known form). The carrier measures the bound executable at plan time and refuses an exchange whose revision, kind or digest differs; a production exchange covers a measured native image only, so a script or launcher form is refused rather than described as covered; the runner measures again before exec. |
| Acceptance authority | `accepted_by` is attribution. Admission enables an exchange only through the host launch policy naming the adapter, the acceptance record and the proven fixture digest; a production policy may name only the adapter the profile itself pins, and matching digests alone activate nothing. |
| Deny acknowledgment | The adapter names the terminal denial that proves a denial was handled (`deny_acknowledgment: terminal_denial` with the observation type, field and value) or declares it `unproven`; the carrier then reports denial dispatch as accepted by the input transport with harness acknowledgment unproven. |
| Pinned measurements | The carrier measures binding, profile, launch policy, adapter and acceptance record from one pinned registry generation; the plan digest carries the acceptance record's digest, not only its reference, so replacing an acceptance entry cannot change an existing plan's evidence. |
| Full revalidation | Before consuming under a new authority incarnation and before any dispatch after recovery, the carrier re-checks that the attempt still waits with a bound runner, that binding, profile, launch policy, adapter and acceptance still measure as planned, that the proposal still digests as recorded, and that the placement, reconciled now, still runs under its grants and projections. A refusal closes the exchange on record; consumption replay never substitutes for it. |
| Late outcomes | A denial, expiry or withdrawal is written as the adapter's deny only while that exact exchange is still waiting and the adapter supports it. After attempt settlement nothing is sent. An approved decision left unused reaches its consumption deadline; its history stays decided. |

## Presentation and acceptance

Use shared shell UI components for requester/destination, requested scope,
status, deadline and available actions. Colors reinforce explicit status text;
labels and scope remain understandable without color. Do not repeat generic
explanations on every item. A decision pending network acknowledgement must not
look committed. Host-selected policy determines whether a request is shown once,
for a session, or is already covered by an existing grant.

The local inbox is `bee.inbox:app` (`src/apps/inbox`), a console-style Bee
application admitted like the others and running under the process actor:
it reads the approval owner's `inbox` for the launch workspace and the
workspaces the host lists in `bee.inbox:workspaces`, opens a request through
`read`, and submits an explicit decision through `decide` with the viewed
revision and proposal digest after the shell's confirmation dialog; a
withdrawal goes through `withdraw` and the owner alone knows whether the
viewer is the requester. Rows lead with the proposed effect (tool or
operation, target, requester, expiry); digests, revisions and the observed
incarnation sit behind a details toggle, and the incarnation shown is what
was observed, not a promise about consumption. Every text from a request is
bounded and stripped of control sequences by `bee.inbox:model`, and a payload
is rendered only as bounded key and value lines. On `CONFLICT` or a settled
state the owner's committed record replaces the view and nothing is
resubmitted; an answer lost in transport leaves one in-flight request that a
`read` recovers; requester, approval owner and effect target are shown apart;
a viewer outside the policy sees the workspace as unavailable and details
refused. The app keeps selection, the details toggle and one in-flight
request; closing it withdraws and expires nothing.
`tests/lua/inbox/surface_test.lua` proves two viewers racing a decision, the
refused outsider, expiry while viewing, the lost answer recovered, close and
reopen, and hostile prompt text against the real owner;
`tests/inbox_app.py` boots the application under the broker.
The application's scope is the broker's composition of the base policies
and its admission binding, and `bee:workspace_storage_boundary` no longer
lists the approvals store, since the owner's methods open it on the
application's behalf; `tests/lua/inbox/admission_test.lua` runs a process
under that exact scope and proves the store denied before and after owner
calls, only inbox, read, decide and withdraw answering, list, consume and
the service library out of reach, and eligibility following the authenticated
actor the process runs under: an actor the approver policy does not match sees
no request and is refused, however admitted the application is. The broker
launches each application as the private actor
`bee.application:<workspace>:<instance>`. A host approver policy may name
that exact actor or use the strict selector
`{definition_id: "bee.inbox:app"}`; a selector matches only the authenticated
actor's definition metadata. In either case the actor also needs
`bee.approvals.decide` for the workspace. Admission alone makes no one
eligible. Separate inbox instances are separate actors, and an accepted
decision records the exact instance actor in its audit history.
`tests/lua/inbox/recovery_test.lua` proves one decision surviving an
interrupted delivery with the owner authority and the inbox restarted and
the delivery replayed once, no cursor advancing past a page that never
arrived and nothing repeated on replayed pages, execution authority
revoked after approval refused without rewriting the decision, and a
headless owner restart with no inbox open recovering the request, the
decision and the pending delivery.

Before implementation is called complete, prove: two clients racing answers;
expiry and cancellation races; unauthorized readers/approvers; changed action
parameters; restart after decision commit before delivery; repeated delivery;
revoked approval before execution; disconnected requester/approver; recovery of
a headless owner's inbox; and remote Terminal launch through an approved exact
scope with denied unapproved access. Preserve existing application-dialog and
close-confirmation behavior during integration.

## Required reusable wait and wakeup contract

Design requirement recorded 2026-09-09; this section does not claim that the
current approvals module implements a general durable workflow engine.
Dataflows, automation and applications need the same durable wait/wakeup
mechanism. The approvals owner decides approvals; a separate reusable work
owner persists waits and dispatches continuations. Do not embed a generic
callback executor in the approval authority.

A continuation is a typed invocation description:

- Function/contract reference, operation/schema revision and admitted executable
  closure or an explicit version-resolution policy.
- Validated serializable arguments, or owner-authorized durable artifact refs
  for larger inputs. The wakeup event has its own declared argument position;
  event data cannot replace the stored function or authorization fields.
- Explicit bounded application context: correlation, logical owner/workspace,
  thread/workflow references and allowed context values. No implicit capture of
  ambient runtime context, closures, database handles or process memory.
- Security binding: authenticated principal, delegation/authorization reference,
  target resource/action ceiling, policy revision and expiry where applicable.
  The trusted dispatcher reconstructs effective security context and rechecks it
  at dispatch. Stored context is not a grant and cannot outlive revoked authority.
- Stable continuation/effect key, deadline, retry/reconciliation policy and a
  durable outcome receipt. An execution has a separate attempt identity and
  incarnation; retry cannot silently select a different function generation.

Thus `function = id + args + context + security binding` describes the persisted
invocation. Security context is established by the owner, not supplied as an
arbitrary serialized runtime frame. Resolve references only through admitted
bindings. Never execute a closure or callback code embedded in an inbox item.

Wait registration and the wakeup checkpoint must eliminate the lost-wakeup
window: register then recheck the authoritative source, or atomically record
source progress and the wait where one owner controls both. A remote source
uses durable subscriptions/outbox delivery and idempotent registration instead
of claiming a cross-node database transaction. Notifications only wake readers;
source records and cursors establish what happened.

Completion, cancellation and timeout compete for one committed waiter outcome.
That outcome and its continuation-dispatch intent commit atomically at the work
owner. Dispatch is at least once with stable keys, an owner-side receipt and
explicit reconciliation after uncertain effects. Claim leases and attempt epochs
fence stale workers; a lease expiring does not prove an external operation stopped.

A persistent process means durable execution state plus a recoverable continuation,
not a promise to serialize an arbitrary Lua stack, Go process or PTY. A resident
worker can sleep or be recreated while inbox records and waiters remain. An inbox
may have a larger host-configured durable budget than its live mailbox; bound its
items, retained bytes, payload size, pending waiters, attempts and retention.
Use explicit capacity errors, backpressure and artifact refs for large bodies.
Never silently evict resumable progress to make room.

Client reconnection restores authorized subscriptions and their per-owner cursors.
Detaching a screen cancels its ephemeral wait, not the underlying workflow or
pending approval. Multiple clients can present the same item without duplicating
its continuation. A reconnect receives the committed decision/execution state,
including unavailable owners and uncertain effects, rather than replaying a click.

Acceptance must cover: source change during waiter registration, disconnected
clients, owner restart, duplicate wakeups, timeout/cancel/decision races, failed
queue admission, a crash after dispatch but before its receipt, revoked security
binding, changed function generation, full inbox budgets, and two clients acting
on one request. Each proof belongs to the relevant owner, independently of the UI.
