# Durable approval requests

`bee.approvals` is the approval owner for one Bee node. It stores requests,
decisions, history, inbox changes and delivery outbox rows in an owner-scoped
database. See [the implementation README](../../modules/approvals/src/README.md) and
[sync and inbox](sync-and-inbox.md) for the surrounding owner-feed boundary.
Application confirmation dialogs are live broker questions; they are not
durable approvals and never grant remote operation authority.

## Ownership and authority

The operation owner decides whether an approval is required and which
principals may answer. Workspace requests belong to the target workspace.
Machine enrollment belongs to the machine authority and does not depend on an
arbitrary project being open. The host selects each database resource; there
is no central approvals database. Sharing a SQLite file does not grant access
to another owner's tables or create a cross-owner transaction.

The authenticated transport peer identifies a node, not automatically a
person. The supervisor establishes the requesting principal/delegation and an
approver's authority. A claimed user name or PID, mesh membership or possession
of an inbox item is not enough. The host policy must grant `bee.approvals.decide`
on the workspace and the actor must match the selected approver policy.
Admission alone does not make an actor eligible. Native Terminal approval
means native execution as the destination OS user; selecting a workspace or
working directory does not confine that authority.

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
`decided`, `expired` and `withdrawn`; a decided request has `approved` or
`denied`. Approval is not execution and does not promise that the operation
will succeed.

`decide` and `withdraw` compare the pending revision, deadline and authenticated
actor in one transaction. Approvals are node-local: a host never exposes
`decide` or `withdraw` over Hive, so a mapped principal reads the feed and a
request but decides nothing, and a decision is always made on the node that
owns the request. The transaction records the new history revision,
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

A decision nobody is told of is not delivered. Only a message commit creates a
recipient obligation, so a transition record states the outcome and owes no
one anything. When a request is bound to a thread, every terminal change
therefore enqueues a second event beside its transition, under
`<approval_id>:<revision>:notice`: a `notification` addressed to the requester
that names the outcome and the approval. An approval, a denial, an expiry and a
withdrawal are announced alike, because what leaves an agent waiting is the
silence rather than the answer. The notice is a side effect of the decision and
never a condition of it: it rides the same outbox, so a thread that refuses it
is retried and finally exhausted in view of `deliveries` while the decision it
announces stands.

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
proposal digest from the opened decision screen. Allow once and Deny each take
one key; permission windows offer duration choices on that screen. `withdraw` is an explicit
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
not look committed. The first intended remote use is a destination-owned
Terminal request through the supervisor; that remote enrollment and execution
flow remains a proposal until its destination admission contract is complete.

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
  for this application, consumes it once, and stores the lease. The envelope
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
  that it starts when the lease is granted, the maximum applies and every
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
request; once a person approves it, `G` on that request grants the lease. `V`
switches to the Active leases view, which lists each lease with its usage,
expiry and envelope and revokes the selected one with `X`. Lease operations
reach a local governance owner only.

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
at one day and retain the default ten-minute request lifetime. Indefinite
"until revoked" authority is unavailable under a finite policy ceiling. Questions
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

`decide` accepts optional positive `window_ttl_ms` on an approved permission
without a response. The owner checks the current policy cap, records who granted
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
settlements that already committed. Grant administration is node-local and has
no Hive exposure; remote Inbox feeds show the owning node's recorded history.

Migration 6 (`approval_windows`, M5) appends the grant store and settlement
references. Its source request stays retained while the window is active;
applied migration SQL, prior ledger checksums, stored approval identities,
projection schema and wire topics remain unchanged.

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

## Proposal: reusable waits and wakeups

Approvals own decisions. A separate work owner would own durable waits and
typed continuations; this section is a design boundary, not a current general
workflow engine or callable API.

A persisted continuation would contain a contract/function reference and
revision, validated serializable arguments or owner-authorized artifact
references, explicit bounded context, a security binding that is rechecked at
dispatch, stable continuation/effect keys, a deadline, retry policy and a
durable outcome receipt. It would never contain a closure, process memory,
database handle or ambient authority. Wait registration would atomically bind
source progress to the waiter, or use a durable subscription/outbox across
owners, so a source change cannot be lost between registration and recheck.

Completion, cancellation and timeout would compete for one committed waiter
outcome. Dispatch would be at least once with leases, attempt epochs, owner
receipts and explicit reconciliation. Client detachment would cancel only an
ephemeral wait, not the workflow or approval. Any implementation must prove
owner restart, duplicate wakeups, source changes during registration, revoked
security, changed function generations, queue limits and uncertain external
effects before this proposal becomes a callable contract.

The Approvals owner exposes runtime approval leases through `bee.approvals.binding:runtime_lease` (also `local.runtime_lease`). Its operations are `grant`, `check`, `use`, `revoke`, `list`; requests carry `operation`, `lease_ref?`, `workspace_id?`, `tool?`, `input_digest?`, `effect_key?`. An ordinary permission approval with operation proposal ref `bee.approvals:runtime-lease` carries `{subject, workspace_id, tool, input_digest, expires_ms, max_uses}`. The digest is lowercase SHA-256; expiry is within 30 days and uses are 1..10000. Grant consumes that exact approved proposal, revalidating its owner incarnation after a restart. Approval migration 5 stores leases and per-effect receipts in the Approvals ledger.

Check/use require consume authority and the exact subject/workspace. Use additionally checks tool/input digest, expiry, revocation and the use bound; the same effect key replays only the same exact operation. Persisted runtime authority survives an owner restart. Subject or workspace manager may revoke; list exposes only the caller's records in one workspace. Saved profile references cannot transfer authority. The shared permission exchange uses matching references before requesting another decision and rechecks the same receipt before dispatch/recovery; Deny still wins.
