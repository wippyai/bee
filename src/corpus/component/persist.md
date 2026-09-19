# bee.persist

Migration mechanics for owned SQLite stores. A component supplies its
resource, its ledger table and label, and its immutable migration list; this
module checks the ledger against that list on every open and applies what is
missing, one migration and one ledger row per transaction. A rebuild
migration runs with foreign keys off on the dedicated connection, outside its
transaction, and is checked before commit.

| Slice | Responsibility |
|---|---|
| `bee.persist` | `ledger`: checksums, ledger replay, apply; `database`: SQLite open with WAL, full sync, foreign keys, busy timeout, then ledger apply |

Consumers: `bee.threads.persist` (ledger `bee_thread_schema_migrations`,
label `thread`) and `bee.placement.native`. `bee.storage:store` still carries
its own workspace ledger and moves here in its own unit.
