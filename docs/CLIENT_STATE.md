# Client layout persistence

Status: the private client actor uses this store and typed layout. Source/pack
tests cover independent desktop actors and client restart against retained host
applications. Normal local launch still uses the workspace envelope. Automatic
host-to-client migration and public independent desktop launch are not wired yet.
Trusted private client bootstrap can now supply a final version-1 options record
with `legacy_desktop`. It imports before client readiness and returns `import_receipt` in
`bee.client.ready` only after the client-store commit. Without an offer, that field
is empty. The source/pack desktop fixture retries the same offer after client exit
and verifies the receipt and later layout are retained.

The workspace host owns application membership, checkpoints and producer
appearance. A desktop client owns placement, tab order, focus, personal titles,
accents and chrome preferences. `bee.client:state` represents the latter using
the existing scene model plus one qualified target per window:

`{tab_id, workspace_id, instance_id, view_id}`

The private local launch selects workspace appearance: its supervisor grants
host-owned preference writes, and bootstrap projects the fresh host preferences
over any stale client copy. Layout and targets remain client-owned. The two stores
do not share a transaction; the host value is authoritative for this local mode.
Ordinary attached clients retain independent chrome preferences. See the
[appearance contract](CLIENT_HOST_SPLIT.md#identity-and-appearance) for commit,
projection, failure and permission behavior.

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

`bee.client:store` defaults to the host-supplied `bee:client_db` resource, separate
from `bee:workspace_db`, runtime registry history and the journal. Protected
bootstrap may instead supply `bee.client.db:<name>` to `open(resource)` for each
independent client. Names contain only letters, digits, underscores and hyphens;
the whole resource ID is bounded to 160 bytes. File paths, wildcards and workspace
database bindings are rejected before acquisition. Native `db.get` still requires
an exact host-selected resource grant; a valid name grants nothing. Normal local
boot does not yet declare that resource. The fixture declares it with an isolated
`BEE_CLIENT_DB` path; the future client launcher must supply its persistent data
binding. Merely disabling `auto_start` is insufficient: native SQLite resources
open their files during registry loading. The client-storage policy grants only
that default database; additional bindings require their own exact policy. The
ordinary application boundary denies both the default resource and all
`bee.client.db:*` and `bee.workspace.db:*` resources, including when an app has a
broader database grant. No current default app receives the
client-storage policy. Native processes still have OS-user file authority.

The private API is `open(resource?)`, `read(handle)`, `write(handle, state)`,
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

There is no cross-database transaction or durable host acknowledgement yet.
The private readiness receipt establishes only the client-side commit; the
supervisor must authenticate the sending client and match its workspace before
using it. The source desktop is retained, so interruption can safely retry the
same offer. No legacy workspace record is deleted or rewritten by client import.
The client store alone does not authorize attachment or restore a native process.
Standalone launch still needs a client-data binding when the new client actor is
integrated; `BEE_CLIENT_DB` is not currently a public workspace-selector command.

`make test` checks mixed-workspace and malformed target values. `make check`
also runs the source/pack Lua storage fixture, restart/retry, existing-layout
protection, failed import and migration rollback, stale writers, schema corruption
and native app database denial. These checks cover persistence. The separate
`client_desktop` fixture exercises two actual private desktop actors.
The storage fixture also selects two client and two workspace resources, writes
different state, restarts and verifies isolation in source and pack. Native
checks reject ungranted resources and broad-grant attempts to bypass the core
database boundary. Normal launch has not yet selected per-client stores; the
private client acceptance fixture supplies explicit bindings.
