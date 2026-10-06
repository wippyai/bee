# bee.persist

Access to the node database `bee:db`, the one SQLite resource every component
stores its state in. SQLite serializes writers on its single connection.

| Entry | Responsibility |
|---|---|
| `bee.persist:database` | `open()` returns `sql.get("bee:db")` or `nil` with a `node database:` error |
| `bee.persist:transaction` | Result values and write/read transactions |

`transaction.write(db, label, body)` runs `body(tx)` in one serializable
transaction: a success commits, a refusal (`transaction.refusal`) commits and
still reports its failure, any other failure rolls back. `transaction.read`
runs `body` in a read-only serializable transaction. A result is
`{ok, code, message, value, replayed}`. `transaction.busy(err)` classifies
SQLite busy (5) and locked (6) from `err:details().sqlite_code`; those become
`BUSY` and every other SQL error `INTERNAL`. Error messages keep the native
text with the failed operation, and a failed rollback or `db:release()`
is appended to the initiating failure. `label` names the store in messages.

## Migrations

Schema changes are `function.lua` entries in the component's migrations
namespace (`bee.<component>.migrations`) with
`meta: {type: migration, target_db: bee:db, timestamp: <UTC>}`, `method: run`
and the import `migration: wippy.migration:migration`. The source returns
`require("migration").define(...)` with `migration(name, ...)`, `database("sqlite", ...)`
and `up`/`down` functions that execute statements on `db`. The `wippy/migration`
dependency (`bee.deps:migration`) applies every migration entry that targets
`bee:db` at boot, ordered by timestamp. Migrations are immutable once shipped;
a schema change adds a new entry with a later timestamp.
