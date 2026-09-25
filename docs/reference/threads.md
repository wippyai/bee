# Threads

Threads are durable, ordered records for messages, observations and managed
work. A thread is a resource owned by one Threads runtime and SQLite store; it
is not a process, terminal view, agent or chat transcript. Views can detach
while the thread, subscriptions and delivery state remain owned by the thread
owner.

The implementation has two compatible surfaces. The actor-owned `journal`
contract keeps its claimed runs and event format. The rich authority,
lifecycle, delivery, projection and carrier contracts use separate tables and
never rewrite or implicitly bridge journal data.

## Ownership and boundaries

Every callable method derives the actor from the authenticated security
context. A request body cannot choose its author. Host-attached policies give
the method access to the selected `bee.threads:database_ref`; they do not give
the caller SQL access. Registry metadata, a claimed producer, a hook name, a
consumer ID or a parent reference is not authority.

Rich thread membership has three roles:

| Role | Rights |
| --- | --- |
| `owner` | Read and write, administer membership, and close the thread. |
| `participant` | Read and submit permitted messages and observations. |
| `observer` | Read only. |

Lifecycle operations have a separate host-granted permission. Membership does
not by itself admit an action, attempt or receipt. The owner checks membership,
state, revisions and the operation's grant inside the same write transaction.
The legacy journal remains actor-owned and is not made accessible by rich
membership.

The module owns its SQLite resource and migration ledger. One runtime must own
the file; opening the same file from multiple runtimes is unsupported. A
resource reference can select another owner-managed database, but it does not
replicate history or merge table authority. A mesh or client connection must
call the owning contract.

The implementation is split into these Lua namespaces:

| Namespace | Responsibility |
| --- | --- |
| `bee.threads` | Journal compatibility, local bindings, resources and capability reporting. |
| `bee.threads.records` | Typed decoders, bounds and canonical record encoding; no I/O. |
| `bee.threads.service` | Thread authority, membership, messages, action inboxes, lifecycle and owner-qualified send. |
| `bee.threads.delivery` | Recipient obligations, claim batches, dispatch, waits and subscriptions. |
| `bee.threads.projection` | Record-derived recap and status checkpoints. |
| `bee.threads.carrier` | Attempt carrier epochs, provenance, stream records and checkpoints. |
| `bee.threads.approvals` | Authenticated approval records projected from the approval owner; it does not decide approvals. |
| `bee.threads.persist` | The database, checked migrations, owner incarnation and readers/transactions. |

## Authority and records

The authority exposes `create`, `get`, `list`, `list_workspace`, `join`, `leave`, `close`,
`record` and `read_after`. Every mutation has a thread ID and idempotency key;
membership and thread state are checked within the transaction. `join` accepts
`participant` or `observer`, uses an expected revision, and is owner-only;
`leave` can remove the caller or an owner-selected member, but the owner cannot
leave its own thread. `close` is owner-only and refuses while lifecycle work is
unsettled.

A thread a workspace owns carries that workspace. `create` records the
`workspace_id` of the caller's host-issued identity (an application principal's
from the broker, a gateway subject's from its binding); a request never names
it, and a caller bound to no workspace creates a node-level thread. Summaries
include `workspace_id` when it is set. `list_workspace`
(`{workspace_id, after_thread_id?, limit?}`) pages the threads one workspace
owns in thread order as one range of the index
`bee_thread_heads(workspace_id, thread_id)`; it needs `bee.threads.workspace`
on that workspace (host policy `bee.security.threads:thread_workspace_list_policy`) and no
membership.

Records use schema revision `bee.thread-record@1`. The authority supplies the
record ID, producer, source, timestamp and sequence; callers submit a typed
body and context only. Sequences are assigned at commit and are unique within
the thread. `read_after` returns ordered bounded pages and an explicit
continuation state.

The supported record kinds are:

- `observation` for typed stream, hook, transcript, MCP and Bee observations;
  observation data includes session state, turn signals, text, tool calls and
  results, notices, execution exits and bounded extensions;
- `message` for requests, progress, replies and notifications;
- `action.admitted`, `attempt.prepared`, `attempt.started`, `turn.request`,
  `turn.end` and `receipt` for admitted work and its lifecycle;
- `delivery.mark` and `request.answered` for recipient delivery facts; and
- `approval.request` and `approval.transition` as approval-store projections.

A message may also name `recipient_action_ids`, the sessions it addresses
by action, and `sender_action_id`, the sending session. The owner accepts a
recipient action only when it is an action of the thread the message lands
on, and a sending action only when an action with that ID was admitted for
the sender. Sessions that share one member identity, such as agents started on
one thread by the same subject, use them to tell who is addressed and whom to
answer; obligations still follow `recipient_ids`.

Decoders reject unknown fields, invalid variants and invalid references.
Content has one bounded text or artifact reference. Extension payloads are
validated JSON and carry no authority. Approval transitions are decided by the
approval subsystem; recording an approval projection never settles an
operation.

Lifecycle methods are `admit_action`, `prepare_attempt`, `start_attempt`,
`request_turn`, `end_turn` and `receipt`. A prepared attempt contains the
binding, profile and placement references plus their digests and a plan digest.
Starting requires the prepared state; carrier and expected revision/epoch
fences reject stale attempts. A continuation may name the action's latest
attempt receipt as an ordering precondition, but it does not grant authority or
resume a provider session by itself.

## Retry and transaction rules

SQLite writes use an immediate/serializable transaction. Membership, retry
lookup, state transitions, record insertion, indexes and the stored reply
commit together. A failed transaction leaves no sequence gap.

Retrying the same operation with the same authenticated actor, thread and
idempotency key returns the stored result. Reusing that identity with a
different canonical request returns `CONFLICT`; it never creates a second
record. Producer event keys use the same content comparison. Canonical JSON is
used for request identity and stored record envelopes.

Lifecycle admission reserves enough record capacity for required terminal
records. A full thread therefore refuses new work before it can strand an
attempt without a receipt. External side effects remain at-least-once: a
timeout says that no result was observed before the deadline, not that the
side effect did not happen.

## Recipient delivery

A message creates one obligation per recipient. An obligation has one of
`pending`, `claimed`, `delivered`, `answered`, `uncertain` or `abandoned`.
Claims are made only by the recipient actor; `consumer_id` identifies a cursor
and cannot act for another recipient. `claim` returns a bounded claim batch and
stores one delivery per obligation with the current owner incarnation.

The normal delivery sequence is:

1. `claim` records a `claimed` mark and a five-minute claim expiry.
2. `dispatch` records intent before bytes leave. An accepted dispatch becomes
   `delivered`; an unaccepted dispatch remains claimed with dispatch evidence.
3. `ack` can settle a claimed delivery as delivered. `release` returns the
   obligation to `pending` only when no dispatch intent exists.
4. `expire` changes an expired or old-incarnation claim to `uncertain`.
5. The owner or lifecycle authority uses `reconcile` to `redeliver`, mark
   `delivered`, or `abandon` an uncertain delivery. Redelivery preserves the
   prior uncertainty in the record stream.

A terminal reply from the obligated recipient settles the corresponding
request. A duplicate terminal reply replays or conflicts; an owner does not
silently impersonate the recipient. Delivery records and obligations are
distinct from subscriptions.

## Action inboxes

An admitted Bee action has a separate, durable inbox on its own thread.
`inbox_send` commits a request record and the action's next inbox sequence in
one write transaction. The sender is **not** enrolled as a thread member and
cannot read that thread through this permission. Inbox items are separate from
the thread's recipient obligations. `inbox_list` pages only the caller's own
admitted action by inbox sequence, and `inbox_ack` records its explicit
acknowledgment. Both check the admitted principal and workspace.

The recipient thread owner calls `inbox_accept` with an exact `sender_id` or a
`sender_class` (the authenticated actor ID before its first colon), an
`allow` decision, an `expected_epoch` and an idempotency key. Every change to
the allow list advances that recipient action's `grant_epoch`. A send requires
the current epoch, the recipient's acceptance, and the caller's host-granted
`bee.sessions.send` permission on the exact
`<workspace_id>/<node_id>/<action_id>` resource. The owner checks these facts,
the local node, the source action's admitted principal, both threads'
workspace, and inbox capacity inside the write transaction. A stale epoch is
`CONFLICT`; lack of a grant or acceptance is `DENIED`. The bundled host selects
a same-workspace send policy for managed agents. Another host may select the
deny policy or a narrower address policy. The destination owner checks the
authenticated workspace and recipient acceptance on every send.

The owner assigns a record ID and stores the SHA-256 digest of the canonical
`{message_id, content}` payload with each item. Retrying the same actor,
destination thread and idempotency key with the same request returns the
stored receipt; a different request conflicts. Each action holds at most 2,048
inbox items. The target carrier may call `inbox_offer` for only the oldest
outstanding item under its current attempt and carrier epoch. A replacement
carrier reoffers the same record ID and digest. `inbox_transport` records that
the transport accepted the offered input under that fence. An agent's own
`inbox_ack` or correlated reply advances it to `acknowledged` or `replied`.
Transport acceptance does not claim delivery to a running model.
Each item also reports a persisted `delivery_status`. A send to an action with
no live attempt records `waiting_for_restart`; a send to an ended action records
`undeliverable`. These statuses leave the committed record and inbox sequence
intact. An attempt receipt marks outstanding items `waiting_for_restart`; an
action receipt marks them `undeliverable`. A later admitted carrier offer clears
the restart blocker. The raw
receipt `state` still follows `committed`, `offered`, `transport_accepted`, then
`acknowledged` or `replied`.

`inbox_reply` commits a reply in the original sender's action inbox and marks
the referenced request `replied` in the same local transaction. Its explicit
`in_reply_to` points to the request record on the other thread; the owner
verifies the two admitted actions and the request before accepting it. Ordinary
`record` replies still settle only same-thread recipient obligations.

The owner wakes the thread waiter on an inbox commit. A fixture-enabled
Claude structured carrier checks the oldest item on wake and at a bounded
poll interval, then writes its identified stream-json user message between
turns. Its write journal and transport receipt survive carrier replacement;
acknowledgment still requires the agent's own `inbox_ack` or reply. Shipped
production launch policies do not enable this push path. A production policy
enables it with `push_acceptance`: the carrier admits the push only where the
pinned binding, profile, adapter and executable measurement still match the
host's acceptance record, and refuses a swapped executable before any launch.

A fresh attempt on a structured driver without a between-turns controller
starts carrying its oldest outstanding inbox item in the brief: Codex, agy,
Grok and Muse launches close stdin or pass the brief as an argument, so the
brief is the only channel. Claude keeps its controller push and windows keep
their hook boundary; resumed attempts keep their provider session, since no
fixture proves inbox-carry combined with those. A fresh sequential attempt on
an already-admitted action attaches to its own action and chains the latest
settled attempt; anything else fails closed with the admit refusal. PTY
windows currently need an explicit `session_inbox` call. Cross-node sends
persist to the durable forwarding outbox addressed at their node instead of
committing locally; the destination admits `inbox_describe` and `inbox_send`
through the Hive principal mapping with re-authorization, below.

`inbox_describe` returns an action address with workspace, current grant
epoch, attempt state and latest inbox delivery state. A caller may describe another action
only with `bee.sessions.discover` on its exact address in the same workspace;
this permission grants neither message content nor send authority.

`wait` claims pending obligations for its recipient, reads new records and then
waits when both are empty. It checks before registration, registers with the
supervised waiter, checks again, treats wakeups as hints, and performs a final
authoritative check before timeout. The maximum wait is 60 seconds, reduced by
the trusted transport budget and its margin. Registration is bounded to 64
waits per thread and 1,024 per node; a missing waiter falls back to bounded
polling. `watch` has the same wakeup path but is read-only and never claims an
obligation, so a viewer cannot alter delivery state.

An authority may project into a thread without being a member of it. The
approval ingress commits its notices as `message` records under its own
producer scope and event id, so they create obligations exactly as a member's
message does and a repeated projection replays the record rather than owing the
delivery twice. That ingress accepts only a `notification` that names at least
one recipient, is sent under the calling actor and answers nothing: an ingress
holding no membership must never place a request nobody could be held to. Only
an active member can ever claim an obligation, so a recipient who has left is
still named by the recorded notice but owed nothing: the projection reaches the
thread, and no obligation outlives the membership that could have settled it.

## One-shot notices

`notify` registers a notice on the caller's own thread: tell me once when an
action of a thread I may read ends a turn or an attempt. The caller must be an
owner or participant of its thread and an active member of the target thread;
a named recipient action must be the caller's own action on its thread. The
notice starts at the target thread's head. The first later record of the
target action that is a `turn.end`, a `receipt`, or an observation
`turn.signal` with phase `ended` or `execution.exit` delivers it: the owner
commits one `notification` message on the watcher's thread under the
watcher's identity and the notice's key, addressed to the watcher and its
action, with the ending record as causation and its outcome when it states
one. A target action with no live attempt is reported at once from its latest
settlement.

The owner settles notices after every commit on the target thread and sweeps
pending notices when it starts and every five seconds, so a notice whose
ending record committed without a settling pass is still delivered once. A
watcher that is no longer an active submitting member of its thread, or whose
thread closed, has its notice cancelled. A thread holds at most 64 pending
notices. Waiters on the watcher's thread are woken by the delivery.

## Subscriptions and sessions

A subscription is a durable consumer cursor over the immutable record stream.
It has an authenticated actor, consumer ID, normalized filter and digest,
durability, owner authority, owner incarnation and lease generation. It is
independent from recipient obligations and from a view's visual cursor.

`subscribe` creates a subscription; `page` hands out one bounded range at a
time; `ack_page` names the exact page ID and `scanned_through` value. The owner
advances the cursor only after that acknowledgment. Repeating `page` while a
page is outstanding returns the same page. Filter changes create a new
subscription identity. `unsubscribe` preserves the durable cursor, `resume`
installs a new lease, and owner-authorized `close_subscription` suspends a
subscription while preserving its cursor. `forget_subscription` deletes only a
closed subscription and reclaims its capacity.

The consumer session follows these rules:

| Situation | Result |
| --- | --- |
| Transport loss | The session is detached; no cursor or page is acknowledged. |
| Same owner authority, incarnation and lease | Reconnect continues from the owner's cursor. |
| New incarnation or lease | `resume` is required; old pages are fenced. |
| Older generation or a cursor behind the owner's cursor | Stale information is ignored and cannot roll progress back. |
| Different owner authority, closed subscription or replacement | Reset and re-admit, or resume only when the owner reports a retained closed subscription. |

The session compares incarnation and lease generation only within one durable
owner authority. The owner process establishes the incarnation at startup;
the waiter cannot advance it. Confirmed deliveries survive an owner restart;
unacknowledged claims need reconciliation and old claim controls fail with
`CONFLICT`. Durable subscription cursors survive, but active leases must be
rebound.

## Owner-qualified send

The destination reference for a remote thread is
`{node_id, service_id = "bee.threads", resource_ref = thread_id}`. `send`
accepts the destination thread, caller node ID, idempotency key, canonical
message, SHA-256 payload digest and optional context. The destination owner
must authenticate the forwarded principal and apply local membership and
operation policy; no actor ID supplied in the payload can retarget it. The
request identity includes the principal, caller node and key, so subjects on
one node do not collide. `send_status` reports a committed record or
`committed = false`; that result means only that no matching commit was visible
at that read. An identical replay remains safe after an ambiguous timeout.

The local send contract and its retry rules are implemented. Supervisor
forwarding between independent runtimes, remote enrollment and the two-runtime
proofs for commit-before-reply loss, replacement, duplicate delivery and stale
acknowledgment are not enabled. A failed owner lookup is an error; it never
falls back to a local thread with the same name.

## Cross-node inbox forwarding

An inbox address is node-qualified as `{node_id, action_id}`. A send whose
node is not local persists to the durable outbox (`bee_thread_inbox_outbox`)
keyed by sender thread, actor and idempotency key, and never commits to a
same-named local thread; resending the same key returns the row's current
state as status, while anything else under the key conflicts. A pump leases
due rows, delivers each through the destination's Hive admission, and settles
only on the destination reply; the destination deduplicates on the sender's
stable key, so a lost reply repeats the delivery rather than duplicating the
message, and only the row's sender claims or settles it.

The destination admits `inbox_describe`, `inbox_send`, `inbox_reply`,
`notify` and the bounded `delivery:watch` for mapped principals under the
host-selected scope. Lookup returns the address with workspace, epoch,
attempt and delivery state through the owner-or-discover gate. A forwarded
send re-authorizes workspace, send grant, target action and epoch for the
mapped principal: the sender action lives on the caller node, so the sender
action claim is attested by the authenticated caller while acceptance,
grant, action admission, epoch and digest are re-checked against
destination state, and the commit records the caller node. A local actor
naming a foreign caller node is denied. A cross-node reply is a forwarded
send that also carries its reply correlation: the node that received the
request validates the correlation against its own inbox item and marks it
replied before anything crosses the wire, and the destination re-authorizes
the mapped principal against its own acceptance, grant, action and epoch
when it commits. A forwarded notice registers the mapped principal's
one-shot watch on a thread it is a member of on the destination, and a
forwarded `delivery:watch` reads one bounded page; in both cases the
destination thread owner still decides membership, and a principal it has
not admitted is denied whatever the payload says. Destination notices and
watches still settle on forwarded commits. The outbox pump is a supervised
`bee.threads.service:pump_worker` process: it leases due rows across every
sender, delivers each through the destination's admission and settles only
on the destination's own reply, so an unknown outcome settles nothing and
the lease lapses. Its transport is host-selected through the `sender`
requirement: the bundled host links `bee.hive.service:inbox_sender`, and a
composition that links no sender leaves due rows queued and reports each
delivery unknown. `session_send` and `session_reply` also
accept a node-qualified remote address: the gateway asks a host-selected
remote resolver (the bundled host links `bee.hive.service:remote_sessions`,
which performs the destination owner's `inbox_resolve`) for the thread and
workspace the address names, and sends there with the same body it would send
locally. Resolution is discovery, not authority: the destination owner
authenticates the forwarded principal and re-checks workspace, send grant,
target action and epoch when the send arrives, and a composition that links no
resolver answers a remote address as not found.

## Carrier and projections

The carrier claims a fenced epoch for one live attempt. `commit` stores up to
64 decoded stream, hook or control records, their source provenance and the
next checkpoint in one transaction. Hook-sourced records are typed
observations, such as the turn signal a `Stop` hook reports; raw hook events
stay `bee` control records. Provenance revision is
`bee.carrier.provenance@1`; checkpoint revision is
`bee.carrier.checkpoint@1` and its encoded state is limited to 64 KiB. Replayed
stream positions are idempotent and different content at the same position is
`CONFLICT`. A stale carrier cannot commit after replacement.

Recap and status are projections of immutable records. They are rebuildable and
never settle work. Recap keeps at most eight summary lines of 120 bytes each;
projection checkpoints store their cursor and digest. A fold reads a bounded
record prefix and commits the checkpoint and cursor together, so a projection
cannot claim a cursor for facts it did not fold.

## Bounds and storage

Shared decoder and database limits are:

| Item | Limit |
| --- | ---: |
| Identifier | 160 bytes, nonempty and without control characters |
| Encoded record/body | 16 KiB |
| Read, claim, wait or carrier page | 64 records |
| Records per rich thread | 10,000 |
| Active members, actions, attempts or turns per thread | 128 |
| Recipient obligations per thread | 2,048 |
| Subscription rows per thread | 128 |
| Durable inbox items per action | 2,048 |
| Array items | 64 |
| Extension JSON depth | 16 |
| Thread title | 512 bytes |

The checked migration ledger carries the legacy journal, rich authority,
lifecycle, delivery, projection, carrier, approval, owner-authority, notice
workspace-attribution and action-inbox schema. Migration 10 (`workspace_attribution`) adds
the head column and its index and attributes existing threads whose owner is
an application principal (`bee.application:<workspace_id>:<instance_id>`) to
that workspace; every other existing thread stays node-level.
Migration 11 (`action_inbox`) adds acceptance epochs, rules and ordered inbox
items without changing prior records. Migration 12 (`action_inbox_push`) adds
fenced offer and transport receipt fields. Migration 13
(`action_inbox_delivery_status`) records restart and ended-action blockers.
Applied migrations and their checksums are immutable. The owner keeps all
table access behind typed contract methods; callers do not query another
subsystem's tables or reset the database to bypass a migration failure.

## Limits of the current implementation

Threads are local-owner durable storage. They do not provide database
replication, compaction, cross-database transactions, federated membership or
exactly-once execution of external effects. Remote callers need an authenticated
owner contract once forwarding is implemented. Wakeups are hints and delivery
is at least once, so consumers and projections must tolerate duplicates and
use the stored identity rules.

The acceptance surface is covered by `tests/lua/threads`,
`tests/thread_storage.py`, the Timeline application checks and `make threads`.
These checks cover typed records, authority roles, lifecycle fencing,
transactional retries, delivery recovery, wait registration and timeout,
subscription page/lease fencing, projections, carrier provenance and
migration integrity.
