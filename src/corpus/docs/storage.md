# Workspace storage

`bee.storage:store` is the persistence boundary for the workspace host.
`open()` acquires `bee:workspace_db`; protected bootstrap may pass
`open("bee.workspace.db:<name>")` to isolate additional workspace owners. Names
contain only letters, digits, underscores and hyphens, with a 160-byte total ID
limit. The root registry owns each resource's path and lifecycle. Callers cannot
pass file paths, select client resources or change tables. Native `db.get` must
grant the selected resource explicitly; the existing default policy grants only
`bee:workspace_db`. Default applications cannot import this library, and their
storage boundary denies both default core stores and the reserved client/workspace
database namespaces even under a broader database grant.

The default workspace file is `.wippy/workspace.db`, and `BEE_WORKSPACE_DB`
can provide an explicit path for an isolated workspace. Wippy registry history
remains separate in `.wippy/registry.db` (or its configured
`registry.history_path`).

Local desktop layout belongs to `bee:client_db`, at the selected workspace path
plus `.client`. The desktop client cannot acquire the workspace store. See
the [desktop contract](../guides/desktop.md) for qualified tab identities and generations
checks and the once-only import from older combined desktop state.

The core-only storage API is:

```lua
local storage = require("store")
local store, err = storage.open()
local workspace_id, identity_err = store:identity() -- stable opaque ID
local state, read_err = store:read() -- nil, nil before the first write
local ok, write_err = store:write(encoded_json)
store:close()
```

State is returned and accepted as a JSON string so the workspace owner remains
responsible for the typed desktop and application resume envelope. A value must
be a JSON object with `version = 1` and is limited to 2 MiB. The storage layer
checks syntax and the top-level version; the workspace protocol validates
desktop geometry, preferences, application identities and opaque resume records.

The database uses four workspace-owned tables. Migration 2 adds `workspace_identity`, a
singleton containing an opaque 32-character lowercase hexadecimal ID. It is
generated once inside the migration transaction, independently from the state
envelope. This ID names a workspace; it does not grant authority. There is no
identity-write method. Reopening, relocating or backing up a
database retains its ID; a fresh database receives a new ID. Copying a database
therefore makes a backup with the same identity, not an independent writable
workspace. Missing or malformed identity after migration causes `open()` to fail;
Bee never repairs it by silently minting a new ID. Migration 1 remains unchanged.

`workspace_state` is a singleton row containing
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

Migration 4 adds `workspace_application_thread_bindings`, keyed by the logical
`instance_id`. The core-only `bee.storage:thread_bindings` helper prepares one
immutable `{thread_id, definition_id, actor_id, role}` identity with one bounded
idempotency key, then advances its revision through `pending`, `active` and
`revoked` with expected revision/state compare-and-swap checks. Exact prepare
retries replay the stored row; changed identity or key input conflicts. Revocation
is durable before any owner performs external cleanup and cannot be undone.
Recovery lists only pending and active rows, while revoked rows remain as
tombstones. The row contains no process, launch, mount, scope, execution,
database or application-data fields, and the helper is not part of ordinary app
imports.
