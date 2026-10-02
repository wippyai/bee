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

Owned-store consumers include `bee.approvals`, `bee.credentials.persist`,
`bee.gateway`, `bee.gov.persist`, `bee.placement.native`, `bee.resources.persist`,
`bee.sync.persist`, and `bee.threads.persist` (ledger
`bee_thread_schema_migrations`, label `thread`). `bee.storage:store` still
carries its workspace ledger. Moving that ledger here remains a proposal.

Missing migrations announce their owner label and old/new revision before work,
and completion after commit, through `bee.persist:startup_progress`, backed by the native host environment.
The owning store scope grants reads and writes only to this progress field; no terminal is required.
Stores report while retained startup is active; ready owners and isolated compositions expose an empty field.
Verification advances progress as ledger rows are first checked; repeated or regressing checkpoints do not renew startup waits. Cache and
migration activity let the retained launch distinguish slow work from a stall.
Migration SQL and checksums remain unchanged.
