# Node storage

A node keeps its durable state in one SQLite database, the resource `bee:db`
(`kind: db.sql.sqlite` in `src/_index.yaml`, `foreign_keys: true`). Its file is
`.wippy/bee.db` under the node's state directory unless `BEE_DB` names another
path. Registry history is kept apart by the runtime.

## Ownership

Each component owns the tables with its own prefix and no other component
writes them. A shared database does not share table authority.

| Component | Tables |
|---|---|
| `bee.node` | `bee_node_workspaces`, `bee_node_desktops`, `bee_node_instances`, `bee_node_settings` |
| `bee.threads` | `bee_thread_*`, `bee_session_*` |
| `bee.approvals` | `bee_approval_*` |
| `bee.gov` | `bee_governance_*` |
| `bee.gateway` | `bee_gateway_*` |
| `bee.resources` | `bee_resource_*` |
| `bee.credentials` | `bee_credential_*` |
| `bee.placement` | `bee_placement_*` |
| `bee.sync` | `bee_sync_*` |

Aggregates and caches are projections an owner can rebuild.

## Schema

A table is created by a migration entry in the component's `migrations`
namespace:

```yaml
- name: workspaces
  kind: function.lua
  meta:
    type: migration
    target_db: bee:db
    timestamp: '2026-10-03T00:00:00Z'
  source: file://workspaces.lua
  method: run
  imports:
    migration: wippy.migration:migration
```

`bee.deps:migration` depends on `wippy/migration` with `app_db = bee:db`; it
applies every pending migration that targets `bee:db` at boot, in `timestamp`
order, and records each in its ledger. The source defines `up` and `down`
inside `migration(...)` and `database("sqlite", ...)` blocks. An applied
migration is not edited; a schema change is a new entry with a later timestamp.

## Access

`bee.persist:database` opens the node database (`open()` returns a `sql.DB`
for `bee:db`) and `bee.persist:transaction` runs write and read transactions
over it. SQLite serializes writers on the resource's single connection; a busy
database fails the write with `BUSY` after rollback.

Access is a security grant: an actor needs `db.get` on `bee:db`. An application's scope
holds no grant on the node database beyond what its admission names, so it
does not open it. It reads and writes through an owner's contract, or through an isolated
database granted by the `app.database` capability.

`bee:changes` (`db.cdc.sqlite`) streams inserts, updates and deletes of the
node database; a subscriber names the tables it follows (`bee.threads.service`
follows `bee_thread_records`).

## Workspace folders

`bee.env:workspace_root` is the folder the node runs in. The node's workspace
rows, desktops and kept app instances live in `bee.node:workspaces`; see
`docs/workspace_catalog` and `docs/workspace_state`.
