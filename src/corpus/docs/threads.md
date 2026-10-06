# Threads

Threads are durable, ordered records for messages, observations and managed
work. A thread is a resource owned by one Threads service and the node SQLite
database (`bee:db`); it is not a process, terminal view, agent or chat
transcript. Views can detach while the thread, subscriptions and delivery
state remain with the owner.

The `authority`, `lifecycle`, `delivery`, `projection`, `carrier` and
`approvals` contracts commit typed records in their own tables. The `journal`
contract keeps Sessions state, immutable work, fenced turns and receipts in the
same record stream and transactions; see `component/sessions` and
`component/threads`.

## Ownership and boundaries

Every callable method derives the actor from the authenticated security
context. A request body cannot choose its author. The policies attached to a
method give it access to `bee:db`; they give the caller no SQL access.
Registry metadata, a claimed producer, a hook name, a consumer id or a parent
reference is not authority.

Membership has three roles:

| Role | Rights |
| --- | --- |
| `owner` | Read and write, administer membership, and close the thread. |
| `participant` | Read and submit permitted messages and observations. |
| `observer` | Read only. |

Lifecycle, carrier, observation and approval operations need a separate
host-granted action (`bee.threads.lifecycle`, `bee.threads.carrier`,
`bee.threads.observe`, `bee.threads.approval`); `bee.threads.create` permits
creating a thread. Membership alone does not admit an action, attempt or
receipt. The owner checks membership, state, revisions and the grant inside
the same write transaction.

One service must own the database. A mesh or client connection calls the owning
contract; it does not read another node's tables.

| Namespace | Responsibility |
| --- | --- |
| `bee.threads` | Contracts, `types` and `record_types`, and the `threads.*` Hive route. |
| `bee.threads.records` | Typed decoders, thread capacities, sequence checks and canonical record envelopes; no I/O. |
| `bee.threads.binding` | The functions that implement the contracts, and the local contract bindings. |
| `bee.threads.service` | The `threads` owner process, authority, access, lifecycle, notices, action inbox, owner-qualified send, the forwarding outbox pump and the Sessions work store. |
| `bee.threads.delivery` | Recipient obligations, claim batches, dispatch, waits and subscriptions. |
| `bee.threads.projection` | Record-derived recap and status. |
| `bee.threads.carrier` | Attempt carrier epochs, provenance, stream records and checkpoints. |
| `bee.threads.approvals` | Approval records projected from the approval owner; it does not decide approvals. |
| `bee.threads.persist` | The database, transactions, owner incarnation, readers, journal SQL and the outbox repository. |
| `bee.threads.sessions` | The Sessions contract and its owner, client and types. |
| `bee.threads.migrations` | Migrations of the thread tables. |

## Authority and records

The authority contract has `create`, `get`, `list`, `list_workspace`, `join`,
`leave`, `close`, `record`, `read_after`, `send`, `send_status`, `notify`,
`register_app_alias`, `retire_app_alias` and `fence_app`. Every mutation has a
thread id and an idempotency key; membership and thread state are checked in the
transaction. `join` accepts `participant` or `observer`, takes an expected
revision and is owner-only. `leave` removes the caller or, for the owner, a
selected member; the owner cannot leave its own thread. `close` is owner-only
and refuses while lifecycle work is unsettled.

`register_app_alias`, `retire_app_alias` and `fence_app` belong to the
application broker. The broker attests each opened instance for its app's stable
identity (an actor of the form `bee.application:<workspace_id>:<instance_id>`;
the family is the definition plus workspace, refined by the overlay owner for
governed apps), retires it when the instance closes and fences the family out of
every thread when admission is lost. An instance without its own member row
still reads and lists the active threads its family owns, so a reopened app
keeps its threads. Guest memberships stay per instance.

A thread a workspace owns carries that workspace. `create` records the
`workspace_id` of the caller's host-issued identity (an application principal's
from the broker, a gateway subject's from its binding); a request never names
it, and a caller bound to no workspace creates a node-level thread.
`list_workspace` (`{workspace_id, after_thread_id?, limit?}`) pages the threads
one workspace owns in thread order. It needs the action `bee.threads.workspace`
on that workspace (policy `bee.threads.security:workspace_list`) and no
membership.

Records use schema revision `bee.thread-record@1`. The authority supplies the
record id, producer, source, timestamp and sequence; callers submit a typed body
and context only. Sequences are assigned at commit and are unique within the
thread. `read_after` returns ordered bounded pages and an explicit continuation.

Record kinds:

- `observation`, from a source of `stream`, `hook`, `transcript`, `mcp` or
  `bee`: session state, turn signals, text, tool calls and results, notices,
  execution exits and bounded extensions;
- `message`: requests, progress, replies and notifications;
- `action.admitted`, `attempt.prepared`, `attempt.started`, `turn.request`,
  `turn.end` and `receipt`: admitted work and its lifecycle, with outcomes
  `succeeded`, `failed`, `cancelled` or `uncertain`;
- `delivery.mark` and `request.answered`: recipient delivery facts; and
- `approval.request` and `approval.transition`: approval-store projections.

A message may name `recipient_action_ids`, the sessions it addresses by action,
and `sender_action_id`, the sending session. The owner accepts a recipient
action only when it is an action of the thread the message lands on, and a
sending action only when it was admitted for the sender. Obligations still
follow `recipient_ids`.

Decoders reject unknown fields, invalid variants and invalid references. Content
is one bounded text or artifact reference. Extension payloads are validated JSON
and carry no authority. Recording an approval projection never settles an
operation.

Lifecycle methods are `admit_action`, `prepare_attempt`, `start_attempt`,
`request_turn`, `end_turn` and `receipt`. Starting requires the prepared state;
carrier and expected revision or epoch fences reject stale attempts.

## Retry and transaction rules

Writes use a serializable transaction. Membership, retry lookup, state
transitions, record insertion, indexes and the stored reply commit together; a
failed transaction leaves no sequence gap. A busy database fails the call with
`BUSY` after rollback.

Retrying the same operation with the same authenticated actor, thread and
idempotency key returns the stored result. The same identity with a different
canonical request returns `CONFLICT`. Producer event keys use the same
comparison.

Lifecycle admission reserves record capacity for the terminal records. A full
thread refuses new work before it can strand an attempt without a receipt.
External side effects are at-least-once: a timeout says no result was observed
before the deadline, not that the effect did not happen.

## Recipient delivery

A message creates one obligation per recipient: `pending`, `claimed`,
`delivered`, `answered`, `uncertain` or `abandoned`. Only the recipient actor
claims; `consumer_id` names a cursor and cannot act for another recipient.
`claim` returns a bounded batch.

1. `claim` records a `claimed` mark and a five-minute expiry.
2. `dispatch` records intent before bytes leave. An accepted dispatch becomes
   `delivered`; an unaccepted one stays claimed with dispatch evidence.
3. `ack` settles a claimed delivery as delivered. `release` returns the
   obligation to `pending` only when no dispatch intent exists.
4. `expire` makes an expired or old-incarnation claim `uncertain`.
5. The owner or lifecycle authority uses `reconcile` to redeliver, mark
   delivered or abandon an uncertain delivery.

A terminal reply from the obligated recipient settles the request. Only an
active member can claim, so a recipient who left is named by the record but owed
nothing. Obligations are distinct from subscriptions.

`wait` claims pending obligations for its recipient, reads new records and waits
when both are empty. It checks, subscribes to the thread's commit events,
checks again, waits for an event or the deadline and checks once more before a
timeout. An event is a hint; the check decides. The wait is at most 60 seconds,
reduced by `transport_budget_ms` minus a one-second margin. `watch` is the same
wait, read-only: it claims nothing, so a viewer cannot alter delivery state.

The approval ingress projects notices into a thread without being a member. They
are `message` records under its own producer scope and event id, so a repeated
projection replays. The ingress accepts only a `notification` that names at least
one recipient, sent under the calling actor, that answers nothing.

## One-shot notices

`notify` registers a notice on the caller's own thread: tell me once when an
action of a thread I may read ends a turn or an attempt. It names a
`target_action_id`, or a `target_attempt_id` whose action may not be recorded
yet. The caller must be an owner or participant of its thread and an active
member of the target thread. The notice starts at the target thread's head. The
first later target record that is a `turn.end`, a `receipt` or an observation
`turn.signal` with phase `ended` or `execution.exit` delivers it: the owner
commits one `notification` message on the watcher's thread, addressed to the
watcher and its action, with the ending record as causation. A target with no
live attempt, or an attempt that already ended, is reported at once.

The owner settles notices after every commit on the target thread and when the
service starts. A watcher that is no longer an active submitting member, or
whose thread closed, has its notice cancelled. A watcher holds at most 64
pending notices.

## Subscriptions

A subscription is a durable consumer cursor over the record stream, with an
authenticated actor, consumer id, normalized filter, owner incarnation and lease
generation. It is independent of obligations.

`subscribe` creates one; `page` hands out one bounded range, and repeating it
while a page is outstanding returns the same page; `ack_page` names the page id
and `scanned_through`, and only then does the cursor advance. A filter change is a
new subscription. `unsubscribe` keeps the cursor, `resume` installs a new lease,
the owner's `close_subscription` suspends a subscription keeping its cursor, and
`forget_subscription` deletes a closed one to reclaim capacity.

| Situation | Result |
| --- | --- |
| Transport loss | The session is detached; no cursor or page is acknowledged. |
| Same owner incarnation and lease | Reconnect continues from the owner's cursor. |
| New incarnation or lease | `resume` is required; old pages are fenced. |
| Older generation or a cursor behind the owner's | Stale information is ignored and cannot roll progress back. |

The service advances the owner incarnation each time it starts. Confirmed
deliveries survive a restart; unacknowledged claims need reconciliation and old
claim controls fail with `CONFLICT`. Durable cursors survive; leases are rebound.

## Action inboxes

An admitted action has a durable inbox on its own thread. `inbox_send` commits a
request record and the action's next inbox sequence in one transaction. The
sender is not enrolled as a member. Inbox items are separate from obligations.
`inbox_list` pages the caller's own action by inbox sequence and `inbox_ack`
records its acknowledgment; both check the admitted principal and workspace.

The recipient thread owner calls `inbox_accept` with an exact `sender_id` or a
`sender_class` (the actor id before its first colon), `allow`, `expected_epoch`
and an idempotency key. Each change advances the recipient action's
`grant_epoch`. A send needs the current epoch, the recipient's acceptance, and
the action `bee.sessions.send` on the resource
`<workspace_id>/<node_id>/<action_id>`. The owner checks these, the source
action's admitted principal, both threads' workspace and inbox capacity in the
transaction. A stale epoch is `CONFLICT`; a missing grant or acceptance is
`DENIED`.

The owner stores the SHA-256 digest of the canonical `{message_id, content}` with
each item. Retrying the same actor, destination thread and key with the same
request returns the stored receipt; a different request conflicts. An action
holds at most 2,048 inbox items. The target carrier's `inbox_offer` takes only
the oldest outstanding item under its attempt and carrier epoch; a replacement
carrier reoffers the same record id and digest. `inbox_transport` records that
the transport accepted the offered input. The agent's own `inbox_ack` or a
correlated reply advances the item to `acknowledged` or `replied`. Transport
acceptance does not claim delivery to a running model.

Each item reports a `delivery_status`. A send to an action with no live attempt
is `waiting_for_restart`; a send to an ended action is `undeliverable`. The
committed record and inbox sequence stay intact; a later carrier offer clears the
restart blocker. The item `state` follows `committed`, `offered`,
`transport_accepted`, then `acknowledged` or `replied`.

`inbox_reply` commits a reply in the original sender's action inbox and marks the
referenced request `replied` in the same local transaction; its `in_reply_to`
names the request record and the owner verifies both actions. An ordinary `record`
reply settles only same-thread obligations. `inbox_describe` returns an action
address with workspace, grant epoch, attempt state and latest delivery state; a
caller describes another action only with `bee.sessions.discover` on its address,
which grants neither content nor send authority. `inbox_resolve` answers a
node-qualified `{node_id, action_id}` with the thread, workspace and epoch that
action names on this node, behind the same gate. An inbox commit wakes waiters on
the thread.

## Owner-qualified send

A remote thread is addressed by its node, `{node_id, service_id = "bee.threads",
resource_ref = thread_id}`. `send` takes the destination thread, caller node id,
idempotency key, canonical message, SHA-256 payload digest and optional context.
The destination owner authenticates the forwarded principal and applies local
membership and policy; no actor id in the payload retargets it. The request
identity includes the principal, caller node and key. `send_status` reports a
committed record or `committed = false`, which means only that no matching commit
was visible at that read; an identical replay stays safe after an ambiguous
timeout.

The node's Hive supervisor hands operations on the `threads` route to the Threads
service. The service forwards `send`, `send_status`, `notify` and `watch`,
rejects a `caller_node_id` that differs from the authenticated caller node, and
calls the binding under the actor `bee.threads.peer.<node>` and the policy
`bee.threads.security:peer`. At most 32 forwarded operations run at once. A failed
owner lookup is an error; it never falls back to a local thread of the same name.

## Application child messages

The host-generated `threads.message` capability with `scope: children` permits
an application to call `bee.threads.binding:send` and `notify` on threads it owns
through managed-agent launch. To steer a child action, `send` a typed `request`
message whose `recipient_ids` names the child's principal and whose
`recipient_action_ids` names its action, with `thread_id`, `idempotency_key`,
`caller_node_id`, `payload_digest` and `message`. After an ambiguous reply, retry
with the same key and body, then read the thread before trying another key. The
grant does not permit `record`. `notify` carries no message body.
`bee.app.threads:client.request` is scoped to the initiating thread and is not a
child-thread messaging route.

## Forwarding outbox

A send to an action whose node is not local persists to the durable outbox
(`bee_thread_inbox_outbox`) keyed by sender thread, actor and idempotency key; it
never commits to a same-named local thread. Resending the same key returns the
row's state; anything else under the key conflicts. The supervised
`bee.threads.service:pump_worker` leases due rows across senders, delivers each
through the destination's Hive admission with `bee.threads.service:pump_sender`
and settles only on the destination's reply, so an unknown outcome settles
nothing and the lease lapses. The destination deduplicates on the sender's stable
key, and a forwarded send is re-authorized there: workspace, send grant, target
action and epoch, with the caller node recorded. A local actor that names a
foreign caller node is denied.

## Carrier and projections

The carrier claims a fenced epoch for one live attempt. `commit` stores up to 64
decoded stream, hook or control records, their provenance and the next checkpoint
in one transaction. Hook-sourced records are typed observations, such as the turn
signal a `Stop` hook reports; raw hook events stay `bee` control records.
Provenance revision is `bee.carrier.provenance@1`; checkpoint revision is
`bee.carrier.checkpoint@1` and its state is at most 64 KiB. Replayed stream
positions are idempotent, different content at the same position is `CONFLICT`,
and a stale carrier cannot commit after replacement. `cancel_intent` records a
durable idempotent cancel of an attempt and `cancel_status` reads it.

Recap and status are rebuildable projections of immutable records and never
settle work. Recap keeps at most eight summary lines of 120 bytes. A fold reads a
bounded record prefix and commits the checkpoint and cursor together.

## Bounds

| Item | Limit |
| --- | ---: |
| Identifier | 160 bytes, nonempty, no control characters |
| Encoded record or body | 16 KiB |
| Read, claim, wait or carrier page | 64 records |
| Records per thread | 10,000 |
| Active members, actions, attempts or turns per thread | 128 |
| Recipient obligations per thread | 2,048 |
| Subscriptions per thread | 128 |
| Inbox items per action | 2,048 |
| Pending notices per watcher | 64 |
| Extension JSON depth | 16 |
| Thread title | 512 bytes |

Migrations live in `bee.threads.migrations` as entries with `target_db: bee:db`
(see `docs/storage`); applied migrations are immutable. The owner keeps table
access behind the typed contract methods.

## Limits

Threads are local-owner durable storage: no database replication, compaction,
cross-database transactions, federated membership or exactly-once execution of
external effects. Wakeups are hints and delivery is at least once, so consumers
and projections tolerate duplicates and use the stored identity rules. The
acceptance suites are `tests/lua/threads` and `tests/lua/sessions`.
