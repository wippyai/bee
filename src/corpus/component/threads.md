# bee.threads

Durable threads in a SQLite store owned by this module. The `authority`,
`lifecycle`, `delivery`, `projection` and `carrier` contracts commit typed
records, membership and work lifecycle for rich threads. The caller's
authenticated actor owns its data and no payload can select another actor.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.threads` | Contracts (`authority`, `lifecycle`, `delivery`, `projection`, `carrier`, `approvals`), local bindings, module resources, the dependency interface and `capabilities`: the implementation report (schema revisions, carried migrations, bound contracts, enforced limits, interim delivery limits) that grants nothing |
| `bee.threads.records` | Pure typed decoders for the seven record families, bounds, the canonical record encoder and canonical JSON for request identity; no I/O |
| `bee.threads.service` | The authority: access facade, authority, action inbox and lifecycle operations, one-shot notices, and owner methods |
| `bee.threads.delivery` | Recipient obligations: claim batches, dispatch intent, acknowledgment, release, expiry, reconciliation; subscriptions with one outstanding page; `wait` and the waiter service |
| `bee.threads.projection` | The recap checkpoint folded from records and committed with its cursor |
| `bee.threads.carrier` | `claim`: a fenced carrier epoch per live attempt; `commit`: derived records (stream observations with provenance in `raw_ref`, `bee.*` extension control records) and the next checkpoint in one transaction under epoch and revision; `checkpoint`: read |
| `bee.threads.persist` | The owned store: checked migration ledger (17 migrations), owner incarnation, connection settings, typed readers and write transactions |

## Dependency interface

| Requirement | Default | Injected into |
|---|---|---|
| `target_db` | `bee.threads:db` | `bee.threads:database_ref` at `.resource_ref`; every open goes through that resource |
| `process_host` | none; `bee.deps:threads` supplies `bee:workers` | `bee.threads:owner_service` and `bee.threads.delivery:waiter_service` at `.host` |

The host keeps `db.get` on the selected resource and `registry.get` on
`bee.threads:database_ref` in the policy it attaches to the methods.
Selecting another resource does not move existing history; each store owns
its tables and migration lifecycle.

## Authority boundaries

Every method preserves the caller's actor; its attached policies only add
storage access. Rights the host grants on the caller's scope, checked with
`security.can(action, thread_id)` inside the operation:

| Action | Permits |
|---|---|
| `bee.threads.create` | creating a thread the caller then owns |
| `bee.threads.observe` | submitting observations as a producer (`stream`, `hook`, `transcript`, `mcp`) |
| `bee.threads.carrier` | claiming a carrier epoch and committing checkpointed records for an attempt |
| `bee.threads.lifecycle` | admitting actions, starting attempts, turns and receipts |
| `bee.sessions.send` | sending to one exact workspace/node/action inbox address accepted by that action's thread owner |
| `bee.sessions.discover` | describing one exact action address without reading its thread |

Membership roles are checked inside the commit transaction: `owner`
administers membership and closes, `participant` reads and submits,
`observer` reads. Lifecycle authority is separate from ownership.

## Delivery

A `message` commit creates one obligation per recipient. A recipient claims
its pending obligations as a batch (`claim`, or `wait`, which claims what is
pending, pages what is new, and otherwise registers with the waiter and
blocks for at most 60 seconds with a final check before any timeout).
Dispatch intent is recorded before bytes leave; `release` returns a claim
to pending only while no intent exists; an expired claim becomes uncertain
and an owner or lifecycle authority reconciles it. A correlated reply
settles the sender's obligation and acknowledges its exact live claim.
Subscriptions are consumer cursors with one outstanding page acknowledged
by identity and exact extent; they never touch obligations. A notice is a
member's one-shot request to be told on its own thread when an action of a
thread it reads ends a turn or an attempt. It can name an action or an attempt
whose action admission has not been recorded yet; the owner binds that pending
attempt notice when its action arrives, settles exact attempt records after
commits on the target thread and on a sweep, and commits the notification once
under the watcher's identity. A message may address sessions by
`recipient_action_ids` and name its sending action; the owner verifies both. Claims and
subscriptions carry the owner incarnation established by
`bee.threads:owner` at startup. The recap is folded from records only.

An action inbox has its own ordered sequence on its thread. `inbox_accept`
lets the thread owner set exact sender or sender-class rules under an epoch.
`inbox_send` verifies the authenticated source action, host send grant,
recipient rule, workspace, node, epoch and capacity, then commits the message
record and inbox item together. `inbox_list` and `inbox_ack` are restricted to
the action's admitted principal. `inbox_reply` commits a cross-thread reply
into the original sender's inbox and marks the request replied in one local
transaction. Neither send nor discovery enrolls the caller as a member.
`inbox_resolve` answers a node-qualified `{node_id, action_id}` address with
the thread, workspace and epoch that action names on this node, so a remote
sender that holds no thread identity can address the inbox; the answer passes
the same owner-or-discover gate a lookup does. The forwarding outbox
(`bee_thread_inbox_outbox`) is drained by a supervised
`bee.threads.service:pump_worker`: it leases due rows across every sender,
delivers each through the destination's admission and settles only on the
destination's own reply. Its transport is host-selected through the `sender`
requirement — the bundled host links `bee.hive.service:inbox_sender` — and a
composition that links no sender leaves due rows queued and reports each
delivery unknown.
`inbox_offer` gives the target's current carrier only the oldest outstanding
item and records its attempt and epoch. A newer carrier may reclaim that same
record and digest after an uncertain dispatch. `inbox_transport` records
transport acceptance under the same fence; it does not acknowledge the item
for the agent. The agent acknowledges or replies through its own inbox tools.
The persisted `delivery_status` is `waiting_for_restart` when a send finds no
live attempt, or `undeliverable` when the action has ended. The item's receipt
`state` remains `committed` until an admitted carrier offers it; an offer
clears the blocker, an attempt or action receipt updates outstanding blockers
in the same transaction, and acknowledgment or reply takes precedence over it.

## Storage

Migrations are an inline ledger checked on every open, one transaction per
migration: 1 `bee_thread_schema_v1` (historical actor-owned journal tables
retained for existing data; current contracts do not access them), 2
`thread_authority` (heads, members, records, commands), 3 `work_lifecycle` (actions, attempts, turns,
settlements), 4 `delivery` (record table rebuilt for the delivery families,
owner, obligations, claim batches, deliveries, dispatch intents,
subscriptions, pages), 5 `projection` (checkpoints), 6 `carrier`, 7
`approvals`, 8 `owner_authority`, 9 `notices`, 10 `workspace_attribution`
(the owning workspace on each head, attributed from application owners, and
the index `list_workspace` walks), 11 `action_inbox` (acceptance epochs, rules
and ordered items), 12 `action_inbox_push` (offer generations and transport
receipt fields), 13 `action_inbox_delivery_status` (persisted restart blockers),
14 `action_inbox_outbox` (the durable forwarding outbox), 15
`action_inbox_outbox_reply` (cross-node reply correlation on a queued row), 16
`cancel_intent` (managed-run cancellation state before the carrier settles),
and 17 `attempt_notices` (durable attempt-addressed notices before action
admission).
Records are stored
as their canonical envelope; extracted columns mirror it. Every mutation
commits its membership checks, retry lookup, head increment, record and
indexes in one transaction; identical retries replay the stored reply and
changed requests conflict. Capacity for the terminal records still owed is
reserved before new work is admitted.
