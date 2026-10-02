# bee.persist

Migration mechanics for owned SQLite stores. A component supplies its
resource, its ledger table and label, and its immutable migration list; this
module checks the ledger against that list on every open and applies what is
missing. The default commits one migration and its ledger row per transaction.
A rebuild runs with foreign keys off on the dedicated connection, outside its
transaction, and checks references before commit. A failed step leaves earlier
committed steps intact.

`ledger.apply(db, config, migrations)` accepts `transaction = "batch"` to commit
all pending migrations and the ledger together. A failure rolls back the entire
batch. Batch mode refuses rebuild migrations, which require their own foreign
key enforcement boundary. `applied_at = false` preserves a ledger with only
`id`, `name` and `checksum`; the default ledger includes `applied_at`.
`freshness_table` names a connection-local temporary table containing one
`fresh` integer: 1 when the batch starts with an empty ledger, otherwise 0.
It requires batch mode and refreshes on every apply, including connection reuse.
The runner takes SQLite's writer lock before reading the ledger inside each
migration transaction, then validates the ledger again so concurrent opens
observe the winning writer's committed steps without applying them twice.

| Slice | Responsibility |
|---|---|
| `bee.persist` | `ledger`: checksums, ledger replay, apply; `database`: SQLite open with WAL, full sync, foreign keys, busy timeout, then ledger apply |

Owned-store consumers include `bee.approvals`, `bee.credentials.persist`,
`bee.gateway`, `bee.gov.persist`, `bee.placement.native`, `bee.resources.persist`,
`bee.sync.persist`, and `bee.threads.persist` (ledger
`bee_thread_schema_migrations`, label `thread`). `bee.storage:store` and
`bee.client:store` use batch mode. Workspace migration 8 consumes
`temp.workspace_migration_run`; its ledger retains `applied_at`. The client
ledger retains its original three columns, without `applied_at` or a new
migration. Each owner keeps its immutable SQL, ledger identity, resource and
schema; this module supplies the runner.

The runner publishes migration checkpoints with lowercase owner labels through
`bee.persist:startup_progress` while retained startup is active. Ledger
verification reports each checked revision, pending steps report their old/new
revision before SQL and their applied revision after the ledger insert, and
completion reports only after commit. A batch completes after its single
commit; rollback never announces completion. The host-selected store scope
grants reads and writes only to this progress field, backed by the native host
environment without a terminal. Ready owners and isolated compositions expose
an empty field. Repeated or regressing checkpoints do not renew startup waits.
Migration SQL and checksums remain unchanged.
