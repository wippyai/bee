# bee.threads

Durable threads in the node database `bee:db`. The `authority`,
`lifecycle`, `delivery`, `projection`, `carrier` and `approvals` contracts commit
typed records, membership and work lifecycle for rich threads. The private
`journal` contract stores Sessions state, immutable work, fenced turns, receipts
and feed events in the same record stream and transaction boundary. Session and
work callers must hold `bee.threads.sessions_owner`. The public session
contracts live in `component/sessions`.

## Slices

| Namespace | Responsibility |
|---|---|
| `bee.threads` | Contracts (`authority`, `lifecycle`, `delivery`, `projection`, `carrier`, `approvals`, `journal`), the `types` and `record_types` libraries and the `route` for Hive operations `threads.*` (service `bee.threads`) |
| `bee.threads.records` | Pure typed decoders for the record families, capacity and sequence checks and canonical record envelopes; no I/O |
| `bee.threads.binding` | The local contract bindings (`authority_local`, `lifecycle_local`, `delivery_local`, `projection_local`, `approvals_local`, `carrier_local`, `journal_local`), their method functions and `capabilities`: the implementation report (schema revisions, bound contracts, enforced limits) that grants nothing |
| `bee.threads.service` | The `threads` owner process (service `service`), the `pump_worker` process (service `pump_service`), and the libraries behind the methods: access, authority, lifecycle, notices, sends, inbox, outbox, app alias and the Sessions `work_store` |
| `bee.threads.delivery` | Recipient obligations: claim batches, dispatch intent, acknowledgment, release, expiry, reconciliation; subscriptions with one outstanding page; `wait`; the session delivery helpers |
| `bee.threads.projection` | The recap and status checkpoints folded from records and committed with their cursor |
| `bee.threads.carrier` | `claim`: a fenced carrier epoch per live attempt; `commit`: derived records and the next checkpoint in one transaction under epoch and revision; `checkpoint`: read |
| `bee.threads.approvals` | `ingress`: approval records |
| `bee.threads.persist` | The store: database access, typed readers, write transactions, owner incarnation, Sessions journal SQL and the forwarding outbox repository |
| `bee.threads.migrations` | Immutable schema migrations |
| `bee.threads.sessions` | The public Sessions contracts, catalog and client |

The journal bindings call `bee.threads.service:work_store` for request validation,
owner and summary-reader permission checks, workspace selection and domain
transitions.
That service calls `bee.threads.persist:journal` through typed functions for all
Sessions journal queries and writes, including scan SQL and stored-row decoding.
The repository uses the caller's existing Threads transaction; it opens no
connection and selects no authority. Journal records, work indexes, turn fences
and operation receipts commit or roll back together.

## Storage

Migrations are `function.lua` entries of `bee.threads.migrations` targeting
`bee:db` (see `component/persist`): `threads` (heads, members, records, commands,
actions, attempts, turns, settlements), `delivery` (obligations, claim batches,
deliveries, dispatch intents, subscriptions, pages), `carrier` (projection
checkpoints, carrier epochs, cancel intents), `notices`, `sessions` (the session
journal), `action_inbox` (acceptance epochs, rules, ordered items and the
cross-node outbox), `app_alias`, `cancel_intent_index` and `sessions_complete`
(the complete session journal schema).
Records are stored as their canonical envelope; extracted columns mirror it.
Every mutation commits its membership checks, retry lookup, head increment,
record and indexes in one transaction; identical retries replay the stored reply
and changed requests conflict. Capacity for the terminal records still owed is
reserved before new work is admitted.

An interactive Session may use an existing workspace thread only when its authenticated application has active owner or participant membership, including a live broker-attested application family. Observer membership and workspace visibility alone do not authorize attachment.

Pull scans exclude settled Work, including Work with retained cancellation records, so cancellation does not block later intake.

The counts-only `bee.threads.binding:node_summary` accepts an empty object and
requires `bee.threads.sessions.summary` on `node`. It returns
`{ok=true,value={running_sessions=N}}` for sessions with accepted execution in
the current owner epoch, excluding closed sessions and unreconciled old claims.
It exposes no session identities, prompts or work records.

The existing owner-only journal `work_scan` accepts optional
`include_hooks = true` for component drain evidence. It includes hook-delivered
work and returns `interactive_active` when a nonclosed hook Session remains,
even with no current Work. The ordinary pull scan retains its existing shape
and filtering. This reads the existing session/work store in one transaction;
no schema or persisted identity changes.

The resident Threads owner runs forwarding rounds as independent scoped
function tasks. Outbox commits activate the pump; the next retry or lease
expiry schedules the next round. Transport waits and pump failures leave the
owner's admission and commit handling available. There is no separate resident
forwarding service.
