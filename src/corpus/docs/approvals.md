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

The proposal and digest are immutable for one decision. Changing an action or
its parameters creates a new request. Requester/key pairs are idempotent;
different content under the same key is a conflict. States are `pending`,
`decided`, `expired` and `withdrawn`; a decided request has `approved` or
`denied`. Approval is not execution and does not promise that the operation
will succeed.

`decide` and `withdraw` compare the pending revision, deadline and authenticated
actor in one transaction. The transaction records the new history revision,
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

The bundled `bee.inbox:app` reads the launch workspace and host-listed
workspaces through the approval owner, displays the proposed effect, target,
requester and expiry, and submits `decide` with the viewed revision and
proposal digest after its confirmation question. `withdraw` is an explicit
requester operation; closing the app expires nothing. All displayed text and
keys are bounded and control characters are removed. A conflict or settled
state refreshes the owner's record and is never resubmitted. A lost answer is
recovered by reading the same request. The app's presentation cannot write
grants or bypass owner policy.

Presentation uses explicit requester, destination, scope, status and deadline
labels; color is only a secondary status cue. A pending network answer must
not look committed. The first intended remote use is a destination-owned
Terminal request through the supervisor; that remote enrollment and execution
flow remains a proposal until its destination admission contract is complete.

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
