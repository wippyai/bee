# Universal approval lifecycle, contract 2

`bee.approvals` is the approval owner for one Bee node. It stores requests,
decisions, history, inbox changes and delivery outbox rows in an owner-scoped
database. See [component/approvals](../component/approvals.md) and
[sync and inbox](sync_and_inbox.md) for the surrounding owner-feed boundary.
Application confirmations use the same request and decision API with inline
or dialog presentation. They record the confirmed gesture and admit one exact
effect without creating a reusable Grant.

## Public contract

Contract version `2` separates the authenticated requester from the authority
subject. Requests carry origin context, an exact registered scope and adapter
identity, evidence references and digests, presentation (`inline`, `dialog`,
`inbox`), an independent effect admission deadline and an optional registered
continuation with a stable effect ID. `reviewed_digest` binds this review; the
original `proposal_digest` continues to identify the unchanged proposal.

`request`, `decide`, `decide_batch`, `withdraw`, `end_request`, `read`, `inbox`,
`feed_snapshot`, `feed_read_after` and `list` manage requests and decisions.
`end_request` records `superseded` or `invalidated`. `grant` provides `check`,
`reserve`, `admit`, `release`, `revoke`, `list`, `read` and `history` for common Grant records across all local domains.
`effect` provides `read`, `claim`, `start`, `complete` and `reconcile`.
`effect_queue` selects uncompleted terminal effects for a registered destination.
`consume` and `revalidate` share effect admission and restart fencing.
`events` reads a durable cursor and acknowledges stable event IDs independently
of thread delivery. `capabilities` reports the version, states and bounds.

Request, Decision, Grant and Effect are distinct durable records. A human
approval admits one exact effect. The request's decision deadline stops a
pending decision; it does not stop an approved effect. New admission enforces
the separate effect deadline. Receipt replay does not spend another use.
Withdrawal checks the pending revision and proposal digest and returns the
committed outcome if a decision wins the race.

Transactional events are `approval.requested`, `approval.decided`,
`approval.denied`, `approval.expired`, `approval.withdrawn`,
`approval.superseded` and `approval.invalidated`. `effect.canceled` records an
unused admission passing its separate deadline; `grant.revoked` records
revocation without undoing already admitted work. Every request owes its
requester a notification, including when there is no thread. Every terminal
outcome authorizes or cancels its waiting effect and owes its registered
consumer an event. Stable IDs and explicit acknowledgment support catch-up
and at-least-once delivery; receivers replay their domain receipts.

Legacy rows retain version `1` provenance, IDs, request/proposal digests,
decision history and effect receipts. Their effect deadline remains their
original expiry, so migration does not extend historical authority.
An unconsumed legacy request binds its first claim to the domain's existing
effect key; every subsequent claim replays that owner and key or conflicts.
Version 2 continuations bind the effect identity before the decision.
An upgraded caller replaying a legacy requester/key receives the original
record and digests. New envelope metadata does not rewrite that record;
changed subject, scope, evidence, destination, admission deadline or original
request fields conflict. The original deadline and effect identity remain
authoritative.
Approval windows, governance leases, follow consent, Docker admission,
saved profile choices, gateway consent and runtime leases use the same Grant
ledger. Domain tables retain enforcement projections and recovery receipts.

A Grant records identity, owner/workspace, subject/audience, exact or envelope
scope, time/use limits, source decision, issuer, provenance and durable history.
Reserved uses and admitted uses have separate counters and receipts. Revocation
fences future reservations and admissions; admitted receipts replay without
undoing completed effects. Persistent `until_revoked` authority requires an
explicit domain policy. Binding grants remain bounded by their live binding. Registered
`bee.approvals.grant-context` metadata names the enforcement projection used
to derive current context expiry/revocation; renewal does not override explicit
Grant revocation. Host-selected consent surfaces create binding-scoped Grants
with policy provenance. Saved profiles keep their original consent Grant pointer.
Gateway dispatch checks the saved profile's exact consent configuration and
uses a separate access Grant for requestable traits, including runtime access.

`grant list` accepts optional `workspace_id` and `after_id`; it returns all
states in pages of 64 with `more` and `next_id`. Node-wide administration needs
`bee.approvals.grants`; ordinary approvers see their own grants in the requested
workspace. `grant read` and `history` return the Grant and history pages of 64;
`after_revision` resumes with `next_revision`. Revoke requires the observed
`expected_revision`. New uses require the exact stored subject/scope.

A registered `bee.approvals.grant-adapter` materializes domain authority inside
the original decision transaction. Operation proposals select it by registered
operation metadata; dynamic attempts may name `proposal.grant_adapter`, a
registered metadata selector included in the proposal digest. These proposals
review their own Grant terms and do not create an additional approval window.
One approval creates one Grant; compatibility grant operations retrieve and
consume the original source effect without a second person ceremony.

Legacy migrations retain recorded actors, exact bounds, old identities where
present, receipt history and explicit legacy provenance. Unrecorded consenting
actors remain unrecorded. Follow progress, Docker provisioning, gateway access
receipts and saved profile configuration survive central revocation, while
future admission checks the live common Grant. Docker consent retains its
original node-wide network and selection scope across workspaces.

## Application confirmations

The common confirmation model and dialog renderer live in
`bee.approvals.app`. Library review, removal, revert and measured Hub
apply/recovery, Settings admission, session/work/app/desktop controls, profile
deletion, Docker revocation, external MCP revocation, login acknowledgment and
Inbox administrative dialogs retain their existing appearance and keyboard
flow. An existing immediate Grant-revoke gesture records an inline Decision
without adding a prompt. Text entry remains an input operation.

A confirmation uses contract 2, `bee.approvals:confirmation`, exact target
scope and a sixty-second request and admission deadline. The host's
`local-confirmation` policy admits only the requesting application instance's
answer. Broker dialogs record the node's authenticated actor and the
originating app/instance. Desktop confirmations belong to the destination
node. App close/stop targets include an opaque execution identity, distinct
from their logical window identity; a replacement execution needs a new
confirmation. Session stop binds the current work reference. Library removal
and revert pass the confirmed installed activation identity to their owner.
Hub proposals retain measured digests, without entered package values.

The confirmed Enter, Space, shortcut or pointer gesture is the existing
`allow_once` or `deny` Decision, with `explicit_gesture` assurance and its
presentation. Inline/dialog requests retain their durable history and requester
events without opening a second Needs you prompt. Repeating the same answer replays one decision; different
assurance conflicts. Escape/cancel withdraws the pending revision with its
proposal and review digests. The model claims the effect through `effect` before the domain action and
preserves incarnation revalidation. The confirmation creates no reusable
Grant, cannot create a window and never authorizes a different target.

Inbox history labels approved confirmations as confirmed and exposes the
authenticated decider, exact action/target and recorded gesture. Existing
unrecorded local confirmations remain unrecorded. Host-policy admission and
credential/resource authorization retain policy provenance; they do not
produce synthetic human decisions.

## Ownership and authority

The operation owner decides whether an approval is required and which
principals may answer. Workspace requests belong to the target workspace. The host selects each database resource; there
is one node-owned approval authority. Sharing a SQLite file does not grant access
to another owner's tables or create a cross-owner transaction.

The authenticated transport peer identifies a node, not automatically a
person. The supervisor establishes the requesting principal/delegation and an
approver's authority. A claimed user name or PID, mesh membership or possession
of an inbox item is not enough. The host policy must grant `bee.approvals.decide`
on the workspace and the actor must match the selected approver policy.
Admission alone does not make an actor eligible. Approving native execution means
execution as the destination OS user; selecting a workspace or working
directory does not confine that authority.

The authority process establishes a node incarnation before serving requests.
A restart creates a new incarnation. An effect owner that observed an older
incarnation receives `REVALIDATE`; it must validate the exact decision under
the current authority before consuming it. The validation is durable and is
invalidated by another restart. Consumption belongs to the effect owner and is
bound to the exact proposal digest and one effect identity.

## Request and decision contract

Each request contains an opaque approval ID, owner/node and workspace identity,
authenticated requester, requester idempotency key, request kind
(`permission|question`), host-selected policy, exact canonical proposal and
its digest, prompt and response schema, audience, revision, expiry and current
state. A proposal may describe an operation or an attempt. If it projects to a
thread, the requester must already be an authorized owner or participant and
the thread binding is stored when the request is made.

Needs you wraps the opened request's bounded prompt so a provider command and
effect remain visible after its session and workspace identities.

The proposal and digest are immutable for one decision. Changing an action or
its parameters creates a new request. Requester/key pairs are idempotent;
different content under the same key is a conflict. States are `pending`,
`decided`, `expired`, `withdrawn`, `superseded` and `invalidated`; a decided request has `approved` or
`denied`. Approval is not execution and does not promise that the operation
will succeed.

`decide` and `withdraw` compare the pending revision, deadline and authenticated
actor in one transaction. Approvals are node-local: `feed_snapshot`, `feed_read_after`, `read`,
`decide` and `withdraw` are the only operations declared as Hive policy
operations, and a decision is always made on the node that owns the request. The transaction records the new history revision,
inbox change and any thread outbox row together. Concurrent answers yield one
committed decision; a retry returns that result and a conflicting answer
returns a conflict. If cancellation races an approval, the reply reports the
owner's committed outcome. Expiry is enforced by owner operations and the
outbox worker, including after restart. Deadlines shown by a client are
informational.

Current bounds are 32 pending requests per requester, 64 records per inbox or
list page, 8 KiB for a canonical proposal, 4 KiB for a response schema and a
default request lifetime of ten minutes. The owner retains settled requests
and deduplication receipts for the configured retention window; retention does
not remove an unacknowledged delivery.

## Agent questions

The additive MCP `question` tool uses the approval owner's contract 2. `ask`
accepts a stable `idempotency_key`, `prompt`, `response_schema` and optional
`ttl_ms`. The gateway binds the authenticated workspace, thread and attempt;
the agent cannot select an approver policy or answer its own question. `read`
returns the same request and its schema-validated response. Poll until the
request leaves `pending`; denial, expiry and withdrawal finish the wait without
an answer. `withdraw` supplies the observed revision and proposal/review digests.

Needs you presents a question card and an Answer action. The typed answer form
uses Library Configure's field declarations, parser, assignment and validation
with the shared UI widgets. Required fields, numbers, booleans and enum choices
retain their types. The owner independently validates the complete response
before committing it. Terminal requester events and thread notices include the
answer, or the reason the question ended. An expired or withdrawn question
closes its open answer form when the inbox catches up.

## Delivery and recovery

A committed projection creates a durable outbox event with a stable event ID,
request revision, target thread and bounded body. The worker leases at most 16
rows at a time, delivers through the narrow thread ingress, and acknowledges
only after the ingress replies. Delivery is at least once; a lost
acknowledgement repeats the same event and the thread deduplicates it. A row is
retried with bounded backoff for at most 12 attempts, then remains visible as
exhausted until an authorized manager returns it to the queue. A queued send is
not execution success. An uncertain native effect is reconciled by its effect
owner before a retry.

A request creates a durable notification obligation to its authenticated
requester. The generic event outbox records each terminal outcome whether or
not the request has a thread. `events` supplies cursor-based catch-up and
acknowledgment; the inbox and live attention signals project that stored state.
When a request is bound to a thread, every terminal change also
enqueues a second event beside its transition, under
`<approval_id>:<revision>:notice`: a `notification` addressed to the requester
that names the outcome and the approval. An approval, a denial, an expiry and a
withdrawal are announced alike, because what leaves an agent waiting is the
silence rather than the answer. The notice is a side effect of the decision and
never a condition of it: it rides the same outbox, so a thread that refuses it
is retried and finally exhausted in view of `deliveries` while the decision it
announces stands.

An uncertain effect keeps its provisional receipt and remains in its registered
consumer queue. Recording uncertainty does not acknowledge terminal events or
mark the effect complete. The consumer reconciles its domain receipt before
recording success, failure or cancellation; identical final receipts replay
and different receipts conflict.

The owner enforces persisted deadlines on every operation and on worker
passes. A disconnected or unavailable owner is shown as unavailable; missing
updates do not imply approval, expiry or deletion. A stale process PID is not a
durable callback target. Delivery adapters use admitted logical destinations,
stable operation IDs and durable acknowledgements; requesters cannot supply
arbitrary executable callbacks, code or recipient addresses.

## Inbox

The inbox is a projection over authorized owners. A client keeps one cursor per
owner and merges bounded pages; there is no global order. Wake notifications
are hints followed by owner `read_after` catch-up. Reads and decisions recheck
current audience and policy. Removing access clears cached sensitive details
and marks the owner unavailable when it cannot be queried.

The bundled `bee.approvals.inbox.app:app` reads the launch workspace and host-listed
workspaces through the approval owner, displays the proposed effect, target,
requester and expiry, and submits `decide` with the viewed revision and
proposal digest from the opened decision screen. `A` allows once and `D` denies; permission windows offer duration choices on that screen. `withdraw` is an explicit
requester operation; closing the app expires nothing. All displayed text and
keys are bounded and control characters are removed. A conflict or settled
state refreshes the owner's record and is never resubmitted. A lost answer is
recovered by reading the same request. The app's presentation cannot write
grants or bypass owner policy.

For workspace application installation, the detail pane also displays the
catalog-resolved capability set, the added or widened permission changes, and
combined data-flow lines. Narrowed and removed permissions are shown when a
new review is needed for another change. The host generates these lines from
its catalog; the app's request reason is not treated as approval wording.
A contained upgrade reuses the live installed grant without creating another
permission request, while widening creates a request for the new delta.

Presentation uses explicit requester, destination, scope, status and deadline
labels; color is only a secondary status cue. A pending network answer must
not look committed.

## Capability envelopes and leases

A contained upgrade needs no decision: when the host-measured capability diff
of a new revision against the installed grant record adds, widens or changes
nothing, the activation reuses the installed grant (see Inbox above).

A person can also lease a bounded envelope for one installed workspace
application. `bee.gov` exposes the destination operations `lease_propose`,
`lease_grant`, `lease_list` and `lease_revoke`:

- `lease_propose` builds the envelope from the installed grant record plus
  optional explicit extras, each validated against the host capability
  catalog, and files an ordinary approval (`bee.gov:grant-lease`) under the
  profile's approver policy. It requires a `ttl_seconds` (at most 30 days), a
  `max_applies`, or both.
- `lease_grant` reads that exact approval, requires it decided and approved
  for this application, consumes its source effect once, and returns the Grant created by the decision. The envelope
  comes from the approved proposal, never from the caller.
- While a lease is active, a revision whose full proposed capability set is
  contained in the envelope is authorized by `bee.gov.lease_apply` without a
  new request. The activation store reserves the use, records its proof (the
  proposal snapshot and the lease's approval identity) and authorizes the
  intent in one commit, and one intent takes one lease authorization.
  Expiry, use count and containment are checked in that commit. A proposal
  outside the envelope, or one that finds the lease expired, exhausted or
  revoked, asks a person as before.
- The effect is admitted when the apply begins, in the same transaction as
  the activation's `begin_apply`. A revocation that lands first fences every
  reservation whose effect has not started (that apply is refused, and
  recovery re-checks the same rule); one that lands after admission reports
  those intents as `started_effects` and does not stop them, because their
  effect began under a valid lease.
- What the limits govern: expiry, `max_applies` and revocation limit new
  lease-authorized reservations and effect admissions. A capability a
  lease-authorized apply installed is an ordinary installed grant afterwards;
  later edits that do not widen it follow the installed-grant rule and do not
  consult or charge the lease. Withdrawing installed authority is a separate
  operation.
- A pending lease approval opens as a full review in the inbox: the
  requester and the request's own expiry, then the target, the duration and
  that it starts when the person approves, the maximum applies and every
  grant of the ceiling, wrapped to the screen and scrollable. Approve stays
  disabled until the last line has been on screen, deny is always available,
  and a lease request cannot join a batch. The ceiling is limited to 16
  grants.
- `lease_grant` is safe to repeat: one approval grants one lease with an
  identity derived from that approval, and a repeated call returns it. After
  an approval owner restart the exact proposal is revalidated and consumed
  under the current incarnation.
- `lease_list` returns the leases able to authorize, plus any lease whose
  reservation still awaits admission (so it can still be revoked); other
  ended leases are history, listed with `history: true`.
- `lease_revoke` returns the intents it fenced and those already admitted;
  the answer is stored with its receipt, so repeating a lost revocation
  returns the same lists.
- `lease_revoke` stops further reservations as described above. Leases are
  keyed by node, workspace and overlay owner; the runtime has no finer
  authenticated principal at this boundary. Super-edit and other overlays
  without a measured capability envelope always ask.

The lease operations need the dedicated delivery action
`bee.gov.delivery.lease`, which the host grants to the bundled inbox. In the
inbox, `E` on an open pending activation request opens a form with an expiry
choice, a max-applies number and up to three ceiling extras (a capability id
and its `key=value` parameters, validated as typed), and files the lease
request. Approval creates its Grant immediately. `U` opens the unified Grants
view; the existing `V` shortcut opens it too. It lists every local domain with
scope, subject/audience, usage, limits and provenance. `H` or Enter opens details
and paginated history; `X` revokes at the displayed revision. Revocation takes
effect immediately. Lease operations reach a local governance owner only.

`decide_batch` settles up to 16 pending requests of one requester in one
workspace in a single transaction. Each item carries the same fields as
`decide`; a mixed batch or a failing item commits nothing. The inbox marks
pending requests with `M` and decides the marked set with `B` (approve) or
`N` (deny) after one confirmation.

## Person-chosen approval windows

On an opened permission request, `A` allows once, `F` allows for 30 minutes,
`L` opens longer choices, and `D` denies. Longer choices are four hours, until
the end of the UTC day, and 24 hours; choices exceeding the smallest policy
ceiling in the displayed batch are absent. The bundled host policies cap windows
at one day and retain the default ten-minute request lifetime. Permanent
"until revoked" windows require explicit host-policy `allow_permanent` opt-in.
Sessions stores its peer consent in common approval-window Grants. Questions
still require their explicit response and cannot create an automatic window.
Governance lease reviews retain their full terms and scroll-before-allow check.

The screen states the subject, capability, scope and duration choice. Pending
permissions from one requester, workspace, authoritative owner and declared
action are displayed as one decision; requests without a declared action group
by requester/workspace. Up to 16 requests settle through `decide_batch` in one
transaction. Its optional `window_ttl_ms` applies to the whole batch, creating
one exact grant per distinct request scope. A mixed or failing batch commits
neither decisions nor grants. A question or governance lease review keeps its
own response/review screen.

A grant covers only the exact requester, workspace, policy and proposal scope
on the native node that owns the approval. Generic proposals require a complete
canonical match. Validated managed permission exchanges retain the exact
attempt/action, plan, adapter, tool and input digest while excluding the two
exchange correlation identifiers. No path wildcard, broader tool permission,
new attempt or other node is authorized. Registry metadata grants nothing.

`decide` accepts optional positive `window_ttl_ms` or `window_permanent=true`
on an approved permission without a response. `allow_grant` requires one of
these reviewed term choices. Windows bind the exact requester proposal;
separately reviewed subjects, scopes, evidence or continuations cannot create
windows. The owner checks the current policy cap or permanent opt-in, records who granted
it, when, and until when, and retains it durably. A matching new request settles
as approved by the grant in the request transaction and records its history,
feed change and thread notices. Its view carries `window_grant` and
`allowed_by_grant`; Needs you displays "allowed by your 30 min grant" (or the
chosen duration). Each request still has its own effect-consumption receipt and
request lifetime. Restart preserves the window; existing decisions still use
the usual incarnation revalidation.

At exact expiry the next request is pending again and its view has `reallow=true`.
The same screen offers Re-allow for 30 minutes, Re-allow longer, Allow once and
Deny, subject to the current policy cap. `U` lists your active grants on the
local authoritative node; `X` revokes the selected grant immediately. The owner
operation `grant_window` supports `{operation="list", workspace_id, after_id?}`
and `{operation="revoke", grant_id, workspace_id?}`. Listing returns `grants`,
`more`, and `next_id` for pages of 64. Decision authority and the issuing actor
or admitted application definition are checked; other approvers cannot revoke
your grant. Revocation stops subsequent automatic decisions without rewriting
settlements that already committed. Grant administration is node-local and declares
no Hive operation; remote Inbox feeds show the owning node's recorded history.

## Storage and migrations

The approval owner opens its host-selected resource through its private
migration ledger. Applied migration text and checksums are immutable; a schema
change is a new migration. Requests, history, inbox and outbox rows commit in
the owner's transaction. Execution receipts belong to the service performing
the operation, not to the approval store. Across stores or nodes, the outbox
and receiver receipt bridge the boundary; there is no distributed SQL
transaction.

Set explicit capacity for pending requests, payloads, outbox backlog and
retention. A full queue returns an error instead of dropping a decision. Do
not persist passwords, enrollment secrets, stream grants, live PIDs or other
credentials in prompts, display text or inbox events.

## Conditional carrier permission exchange

The carrier can represent a harness permission prompt as an approval-bound
exchange when the host launch policy selects a measured permission adapter,
acceptance record and approver policy. Shipped profiles leave this exchange
disabled until the host has the required acceptance. The request identity is
the carrier observation event key; the proposal digest, approval idempotency
key, effect key and input write ID are derived from the owner, attempt and
permission identity. The carrier records intent before requesting approval,
revalidates an approved decision after an authority change, consumes it for one
effect and sends one deterministic response through the carrier write path.

A denial or expiry may be sent only while that exchange is waiting and the
adapter supports it. After attempt settlement nothing is dispatched. A
replacement carrier recovers the approval and pending write from its
checkpoint and asks the fenced runner for status before a first dispatch.
Unknown runner state leaves the write uncertain. Transcript presence or a
permission adapter's eligibility never authorizes an effect by itself.

Accepted driver permission requests carry contract 2 origin identities alongside
the exact tool, input digest, plan and adapter measurement. Claude window/stdio,
Codex window, Agy gates, Grok headless ACP, Muse hooks and the OpenCode window
observer share the same durable exchange. A recorded decision produces one
response write; retries replay the recorded response. Codex and OpenCode batch
contexts and Grok windows retain provider permission handling. Agy's independent
command checks remain provider-owned. Session details show the selected mode and
the descriptor's context-specific ownership explanation.

Transport owners call `withdraw_origin({instance_id})` as the authenticated
requester before sealing or revoking a gateway binding. It withdraws that
requester's pending requests from that instance, emits terminal events, and
records a durable fence against later requests from the same instance. The fence
outlives request retention. Gateway access and capability requests carry the
same binding origin. Replays
of existing requests return their committed outcomes, including decisions that
won a cancellation race. Other transport instances and replacement carrier
epochs retain their own authority. Carriers also withdraw an individual pending
approval before closing its exchange. The approval owner enforces expiry;
a carrier reaching its local deadline withdraws the pending owner request and
uses the committed race outcome instead of declaring a local-only expiry.

## Runtime leases

The Approvals owner exposes runtime approval leases through `bee.approvals.binding:runtime_lease` (also the `bee.approvals.binding:local` binding). Its operations are `grant`, `check`, `use`, `revoke`, `list`; requests carry `operation`, `lease_ref?`, `workspace_id?`, `tool?`, `input_digest?`, `effect_key?`. An ordinary permission approval with operation proposal ref `bee.approvals:runtime-lease` carries `{subject, workspace_id, tool, input_digest, expires_ms, max_uses}`. The digest is lowercase SHA-256; expiry is within 30 days and uses are 1..10000. The original approval creates the exact runtime Grant. The compatibility `grant` operation consumes its source effect, revalidating its owner incarnation after a restart. Runtime authority and use receipts live in the common ledger.

Check/use require consume authority and the exact subject/workspace. New uses check tool/input digest, expiry, revocation and the use bound; an admitted effect key replays the same exact operation after expiry or revocation. Persisted runtime authority survives an owner restart. Subject or workspace manager may revoke; list exposes only the caller's records in one workspace. Saved profile references cannot transfer authority. The shared permission exchange uses matching references before requesting another decision and rechecks the same receipt before dispatch/recovery; Deny still wins.
