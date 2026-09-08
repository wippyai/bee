# Client layout persistence

Status: private store and typed layout values implemented and tested; the local
desktop still uses its existing workspace envelope. Automatic host-to-client
migration and independent desktop launch are not wired yet.

The workspace host owns application membership, checkpoints and producer
appearance. A desktop client owns placement, tab order, focus, personal titles,
accents and chrome preferences. `bee.client:state` represents the latter using
the existing scene model plus one qualified target per window:

`{tab_id, workspace_id, instance_id, view_id}`

Scene IDs are client tab keys. Every target must match its window's workspace
and instance identity. Equal view and instance IDs from different workspaces do
not collide. The current scene limit remains sixteen windows per desktop; this
does not constrain total workspaces or applications hosted elsewhere.

`import_desktop(workspace_id, legacy_desktop)` validates and copies the old
desktop, derives stable tab keys from each qualified target, and preserves
geometry, focus, order, modes and personalization. A foreign window is refused.
It imports no application checkpoint, registry definition, execution PID,
connection ID, policy, catalog or TTY mount. Decoders construct fresh values;
they do not persist unknown fields from incoming tables.

## Owned database

`bee.client:store` uses only the host-supplied `bee:client_db` resource, separate
from `bee:workspace_db`, runtime registry history and the journal. Normal local
boot does not yet declare that resource. The fixture declares it with an isolated
`BEE_CLIENT_DB` path; the future client launcher must supply its persistent data
binding. Merely disabling `auto_start` is insufficient: native SQLite resources
open their files during registry loading. The client-storage policy grants only
that database; the ordinary application boundary explicitly denies it, including
when an app has a broader database grant. No current default app receives the
client-storage policy. Native processes still have OS-user file authority.

The private API is `open()`, `read(handle)`, `write(handle, state)`,
`import_legacy(handle, workspace_id, desktop)` and `close(handle)`. Handles and
their native database fields must remain inside the owning client process.
Each store has a stable random client identity. Reads validate the whole state;
writes compare the generation observed by that handle. A stale writer must read
again and reconcile. Values are bounded to 2 MiB and schema version 1.

The append-only migration ledger verifies its name and SQL checksum. Unknown,
changed or corrupt schemas fail closed. A missing identity after migration is
corruption, not a reason to generate another client. Migration 1 must remain
immutable once deployed; subsequent changes append migrations.

## Recoverable legacy import

The first import writes layout and a random receipt in one atomic SQLite update.
It can initialize only an untouched client store. It cannot replace a layout
the client has already created. Retrying the same workspace returns the original
receipt and does not reset later user edits. A different workspace cannot reuse
that first-import receipt. Adding ordinary tabs from another workspace will use
normal client layout writes, not repeat the legacy migration.

The remaining host/client migration protocol must:

1. Retain the workspace's legacy desktop while offering it to the first client.
2. Wait for the client's durable import receipt before acknowledging completion.
3. On interruption, replay the offer; the existing client receipt makes it safe.
4. Preserve the original workspace ID and application records throughout.

There is no cross-database transaction or implemented host acknowledgement yet.
The client store alone does not authorize attachment or restore a native process.
Standalone launch still needs a client-data binding when the new client actor is
integrated; `BEE_CLIENT_DB` is not currently a public workspace-selector command.

`make test` checks mixed-workspace and malformed target values. `make check`
also runs the source/pack Lua storage fixture, restart/retry, existing-layout
protection, failed import and migration rollback, stale writers, schema corruption
and native app database denial. These are persistence checks, not evidence that
two interactive desktop clients are implemented.
