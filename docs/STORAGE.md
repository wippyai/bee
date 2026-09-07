# Workspace storage

`bee.storage:store` is the small persistence boundary for the workspace and
session core. It acquires the fixed `bee:workspace_db` SQLite resource; the
root registry entry owns that resource's path and lifecycle. Callers cannot
select a different database or table, and default applications do not import
this library or receive `db.get` for the workspace resource.

The default workspace file is `.wippy/workspace.db`, and `BEE_WORKSPACE_DB`
can provide an explicit path for an isolated workspace. Wippy registry history
remains separate in `.wippy/registry.db` (or its configured
`registry.history_path`).

The public API is:

```lua
local storage = require("store")
local store, err = storage.open()
local state, read_err = store:read() -- nil, nil before the first write
local ok, write_err = store:write(encoded_json)
store:close()
```

State is returned and accepted as a JSON string so the workspace owner remains
responsible for the typed desktop and application resume envelope. A value must
be a JSON object with `version = 1` and is limited to 2 MiB. The storage layer
checks syntax and the top-level version; the workspace protocol validates
desktop geometry, preferences, application identities and opaque resume records.

The database uses two tables. `workspace_state` is a singleton row containing
the envelope, schema version, monotonic generation and update timestamp.
`workspace_schema_migrations` is an append-only ledger with integer `id`,
immutable `name`, `checksum` and `applied_at` fields. `open()` enables WAL and
runs every pending migration in one transaction. On every open it checks that
recorded migrations are contiguous, rejects a newer ledger version, and
rejects a changed name or checksum. A failed migration rolls back both schema
changes and its ledger record.

Each write is also transactional. Existing rows update through a generation
compare-and-swap predicate, so a stale transaction cannot overwrite a newer
commit. The value is validated before the transaction and again before
replacing an existing row; malformed or oversized state remains an error and
is never silently discarded.
