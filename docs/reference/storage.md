# Workspace storage

`bee.storage:store` is the persistence boundary for workspace hosts. The node
workspace database holds any number of logical workspaces as rows keyed by
`workspace_id`; a workspace has no database file, process host or runtime of its
own. `open(resource, selection)` acquires `bee:workspace_db` (or, for protected
bootstrap, `bee.workspace.db:<name>`) and binds the handle to exactly one catalog
row. Names contain only letters, digits, underscores and hyphens, with a 160-byte
total ID limit. The root registry owns each resource's path and lifecycle.
Callers cannot pass file paths, select client resources or change tables. Native
`db.get` must grant the selected resource explicitly; the existing default policy
grants only `bee:workspace_db`. Default applications cannot import this library,
and their storage boundary denies both default core stores and the reserved
client/workspace database namespaces even under a broader database grant.

A selection, decoded by `bee.storage:binding`, is either `{workspace_id}` or
`{root_ref, subpath}`. Classic folder mode passes `binding.classic()`, the
workspace rooted at `bee:workspace_root` with an empty subpath. The host is
told its selection by the composition that spawns it
(`bee.host:main(owner, selection, database_resource)`) and never infers the
workspace from the database it opens.

The default workspace file is `.wippy/workspace.db`, and `BEE_WORKSPACE_DB`
can provide an explicit path for an isolated workspace. Wippy registry history
remains separate in `.wippy/registry.db` (or its configured
`registry.history_path`).

Local desktop layout belongs to `bee:client_db`, at the selected workspace path
plus `.client`. The desktop client cannot acquire the workspace store. Desktop
identities (the default desktop and up to 32 allocated ones) belong to the
client node and double as the display IDs workspaces record. Each desktop keeps
one layout per workspace it shows in `client_layouts`, keyed by
`(desktop_id, workspace_id)` with its own generation and import receipt;
`bee.client:store.open(resource, workspace_id, desktop_id?)` binds a handle to
one pair and `bee.client:store.desktops(resource)` lists and allocates
identities. A layout written before migration 3 stays on its identity row until
the first workspace that its import receipt and every target name opens it;
that workspace adopts it in one transaction under the same desktop identity.
See the [desktop contract](../guides/desktop.md) for qualified tab identities and generations
checks and the once-only import from older combined desktop state.

The core-only storage API is:

```lua
local storage = require("store")
local binding = require("binding")
local store, err = storage.open(nil, binding.classic())
local workspace_id, identity_err = store:identity() -- the bound catalog row
local state, read_err = store:read() -- nil, nil before the first write
local ok, write_err = store:write(encoded_json)
store:close()
```

State is returned and accepted as a JSON string so the workspace owner remains
responsible for the typed desktop and application resume envelope. A value must
be a JSON object with `version = 1` and is limited to 2 MiB. The storage layer
checks syntax and the top-level version; the workspace protocol validates
desktop geometry, preferences, application identities and opaque resume records.

The catalog table `workspaces` holds one row per logical workspace:
`workspace_id` (an opaque 32-character lowercase hexadecimal ID), `label`,
`root_ref` and `subpath` (unique together, so one root is one workspace and
lookup by root is an index probe), `state` (`active` or `archived`; `open()`
serves only active rows), `created_at` and `last_used_at`, which `open()`
records. The ID names a workspace; it does not grant authority. There is no
identity-write method. `bee.storage:catalog` holds the row operations (insert,
read, ordered pages, rename and state changes) over a transaction from
`store.database(resource)`; the [catalog operations](workspace-catalog.md) are
the only callers outside tests. Components attach their own per-workspace
tables keyed by `workspace_id`; the catalog carries no component columns.
Migration 7 (`workspace_catalog_order_v1`) adds the indexes
`(state, lower(label), workspace_id)` and `(state, root_ref, subpath)` that
listing and search walk.

Migration 6 (`node_workspaces_v1`) turns a single-workspace install into this
catalog. The ID from the former `workspace_identity` singleton becomes the
classic row (root `bee:workspace_root`, empty subpath, empty label), and
`workspace_state`, `workspace_display_assignments`,
`workspace_display_transfer_receipts` and `workspace_application_thread_bindings`
are rebuilt with `workspace_id` as their leading key; every existing row keeps
its values under that ID. A missing identity row fails the migration instead of
dropping state. Reopening, relocating or backing up a database retains its IDs;
a fresh database receives a new classic ID from migration 2. Copying a database
therefore makes a backup with the same identities, not an independent writable
node. A selection naming no catalog row causes `open()` to fail; Bee never
repairs it by silently minting a new ID. Migrations 1-5 remain unchanged.

`workspace_state` has one row per workspace containing the envelope, schema
version, monotonic generation and update timestamp.
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

Migration 4 adds `workspace_application_thread_bindings`, keyed (since
migration 6) by workspace and the logical `instance_id`. The core-only `bee.storage:thread_bindings` helper prepares one
immutable `{thread_id, definition_id, actor_id, role}` identity with one bounded
idempotency key, then advances its revision through `pending`, `active` and
`revoked` with expected revision/state compare-and-swap checks. Exact prepare
retries replay the stored row; changed identity or key input conflicts. Revocation
is durable before any owner performs external cleanup and cannot be undone.
Recovery lists only pending and active rows, while revoked rows remain as
tombstones. The row contains no process, launch, mount, scope, execution,
database or application-data fields, and the helper is not part of ordinary app
imports.
