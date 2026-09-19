# bee.threads

Durable threads in a SQLite store owned by this module. Two surfaces share
the store: the actor-owned `journal` contract (claimed runs and idempotent
events, unchanged) and the `authority` and `lifecycle` contracts, which
commit typed records, membership and work lifecycle for rich threads. The
caller's authenticated actor owns its data and no payload can select another
actor.

## Slices

| Slice | Responsibility |
|---|---|
| `bee.threads` | Contracts (`journal`, `authority`, `lifecycle`, `delivery`, `projection`, `carrier`), local bindings, the journal client and methods, module resources, the dependency interface and `capabilities`: the implementation report (schema revisions, carried migrations, bound contracts, enforced limits, interim delivery limits) that grants nothing |
| `bee.threads.records` | Pure typed decoders for the seven record families, bounds, the canonical record encoder and canonical JSON for request identity; no I/O |
| `bee.threads.service` | The authority: access facade, authority and lifecycle operations, and one `function.lua` per method in `<name>_method.lua` |
| `bee.threads.delivery` | Recipient obligations: claim batches, dispatch intent, acknowledgment, release, expiry, reconciliation; subscriptions with one outstanding page; `wait` and the waiter service |
| `bee.threads.projection` | The recap checkpoint folded from records and committed with its cursor |
| `bee.threads.carrier` | `claim`: a fenced carrier epoch per live attempt; `commit`: derived records (stream observations with provenance in `raw_ref`, `bee.*` extension control records) and the next checkpoint in one transaction under epoch and revision; `checkpoint`: read. See [the carrier contract](../../docs/CARRIER.md) |
| `bee.threads.persist` | The owned store: checked migration ledger (6 migrations), owner incarnation, connection settings, typed readers, write transactions, the legacy journal and its `store` compatibility surface |

## Dependency interface

| Requirement | Default | Injected into |
|---|---|---|
| `target_db` | `bee.threads:db` | `bee.threads:database_ref` at `.resource_ref`; every open goes through that resource |
| `process_host` | `bee:workers` | `bee.threads:owner_service` and `bee.threads.delivery:waiter_service` at `.host` |

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

Membership roles are checked inside the commit transaction: `owner`
administers membership and closes, `participant` reads and submits,
`observer` reads. Lifecycle authority is separate from ownership. Legacy
journal threads keep actor-only ownership; rich membership never reaches
them.

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
by identity and exact extent; they never touch obligations. Claims and
subscriptions carry the owner incarnation established by
`bee.threads:owner` at startup. The recap is folded from records only.

## Storage

Migrations are an inline ledger checked on every open, one transaction per
migration: 1 `bee_thread_schema_v1` (journal), 2 `thread_authority` (heads,
members, records, commands), 3 `work_lifecycle` (actions, attempts, turns,
settlements), 4 `delivery` (record table rebuilt for the delivery families,
owner, obligations, claim batches, deliveries, dispatch intents,
subscriptions, pages), 5 `projection` (checkpoints). Records are stored
as their canonical envelope; extracted columns mirror it. Every mutation
commits its membership checks, retry lookup, head increment, record and
indexes in one transaction; identical retries replay the stored reply and
changed requests conflict. Capacity for the terminal records still owed is
reserved before new work is admitted.

## Testing

`make test` runs the Wippy suites in `tests/lua/threads`: `records_test`
(decoders and canonical encoding), `authority_test` (roles, retries, producer
dedupe, bounded reads, concurrent writers, rollback), `lifecycle_test`
(transitions, single receipts, capacity reservation, index rollback) and
`ledger_test` (a populated version-1 store upgraded byte for byte, the record
table rebuild, altered and newer ledgers refused), `delivery_test`,
`subscription_test`, `wait_test` and `recap_test`. `make threads-module` boots only this module with a
minimal host and exercises all three contracts with no desktop entries
loaded. `make threads` and `tests/thread_storage.py` cover the journal.
