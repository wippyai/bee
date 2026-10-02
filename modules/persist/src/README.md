# bee.persist

Migration mechanics for owned SQLite stores. A component supplies its
resource, its ledger table and label, and its immutable migration list; this
module checks the ledger against that list on every open and applies what is
missing, one migration and one ledger row per transaction. A rebuild
migration runs with foreign keys off on the dedicated connection, outside its
transaction, and is checked before commit.

Bee's native `sqlerrors` component reads the retained Go error chain at the
Lua boundary. SQL failures retain the native cause, including SQLite result and extended
result codes, with the failing operation. Transaction begin, statement, commit,
rollback and database release failures remain visible to the caller. A cleanup
failure is appended to the initiating failure; it does not replace its cause.

| Slice | Responsibility |
|---|---|
| `bee.persist` | `ledger`: checksums, ledger replay, apply; `database`: SQLite open with WAL, full sync, foreign keys, busy timeout, then ledger apply |

Owned-store consumers include `bee.approvals`, `bee.credentials.persist`,
`bee.gateway`, `bee.gov.persist`, `bee.placement.native`, `bee.resources.persist`,
`bee.sync.persist`, and `bee.threads.persist` (ledger
`bee_thread_schema_migrations`, label `thread`). `bee.storage:store` still
carries its workspace ledger. Moving that ledger here remains a proposal.
