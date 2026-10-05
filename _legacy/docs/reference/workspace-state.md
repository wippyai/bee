# Workspace state and application restoration

This describes the implemented version-1 store, not the future resource catalog.
Workspace hosts alone open `bee.env:workspace_db`, the node workspace database that
keeps every logical workspace as keyed rows. Its source-development default
is `.wippy/workspace.db`; `BEE_WORKSPACE_DB` selects another file. The standalone
executable uses its application state directory by default and preserves the
caller's working directory for native commands. See the [launch instructions](../../README.md).
Each workspace has a durable opaque ID in the node catalog table `workspaces`;
classic launch serves the row rooted at `bee.env:workspace_root`. Selecting a project
folder does not create an authorized filesystem binding.

## Persisted values

The store has a checked migration ledger and one versioned JSON envelope per
workspace, with a
generation used for compare-and-swap writes. See [storage](storage.md) for SQL
ownership and integrity checks. The envelope is bounded to 2 MiB.

| Envelope field | Contents |
|---|---|
| `version` | `1` |
| `desktop` | Workspace appearance preferences and retained legacy scene/tabs for client import |
| `applications` | At most 16 opt-in resume records |
| Each resume record | `id` (view), `instance_id`, `definition_id`, `resume_schema`, `restart_policy`, `resume_state`, optional legacy `window` |

App state is a JSON string bounded to 64 KiB. There are no persisted per-app
checkpoint sequence numbers or pinned definition versions in this envelope.
The workspace ID is stored separately and supplied in application launch values.
New desktop windows and broker replies carry it too. Old local windows without
the field remain readable and are rebound to their owner on reopen. Remote
attachment and cross-workspace request routing remain unimplemented. Runtime launch values include revision information, but recovery
resolves the admitted definition available at boot and checks its declared
resume schema. An installer must not mistake this for version pinning.

The host retains the old desktop projection for a once-only client import; it
does not write new window geometry into application checkpoints. The client stores
committed scene changes, not each drag preview, in its own database. Its import
receipt preserves later edits across repeated boots. See [the desktop contract](../guides/desktop.md).
Host recovery retains resume records for failed or incompatible restores. Runtime PIDs, launch tokens,
TTY mounts and native resources are recreated, never stored as authority.
PID strings may repeat across runtime boots.

## Application contract

`meta.application.resume_schema` and `restart_policy` declare support. The policies
are `never` (default), `automatic` and `manual`. Automatic instances reopen at
boot in saved order; independent restores proceed together and complete as each
application answers. Manual instances resume when opened. Restored launches carry
`resume_schema` and `resume_state`, stable logical IDs and fresh capabilities.

`client.checkpoint(launch, json_string)` returns a queued request ID. Only a
successful `bee.app.checkpoint_result` means database commit. The broker
checks sender, identities and token; the workspace validates and writes the
envelope. One pending request per app is retained; supersession and timeouts have
explicit outcomes. A timeout is not proof the transaction never committed.
See [application contracts](applications.md) for exact messages.

Settings demonstrates opt-in recovery. Terminal declares no cold-resume contract:
a dead native shell cannot be recreated at its prior instruction by saving JSON.
Live F12 presenter replacement preserves its existing PTY. Closing a live instance
removes its resume record after EXIT; exiting the workspace preserves records.
Shutdown does not wait for every app to take a new checkpoint.

## Migration and future boundaries

Applied migration names and checksums are immutable. Newer, changed or incomplete
ledgers fail explicitly; Bee does not delete or downgrade the database. Stale
store handles cannot overwrite a newer generation. These guarantees are tested
in `tests/storage.py`; source/pack restoration is tested in `tests/recovery.py`.

Migrations 9–11 translate the classic catalog root and earlier application IDs.
Migration 12 moves Settings, Terminal, Process Manager and Overlays to their
module application children and completes earlier definition translations in
JSON with arbitrary spacing. It updates only saved application `definition_id`
fields and workspace thread binding definitions; opaque resume state stays intact.
The recovery decoder reads current IDs without aliases. Client layouts contain
view and instance IDs, so their migration ledger stays unchanged.
`make app-layout-upgrade-check` restarts state written by main `463ac2ea` and
checks application identities, layout and the new ledger.

Threads schema migration 28 and data ledger `bee_thread_definition_migrations:1`
move the four relocated definitions and their derived stable memberships,
Sessions ownership, operational filters and receipts in one transaction.
Historical journal records keep their original evidence.

Sync migration 7 updates SDK references in saved profiles, feed events and
idempotency receipts. Gateway migration 15 updates stored surfaces, active
traits and grant receipt trait lists. Both owners translate exact SDK reference
strings without changing approval proposal digests or actor identities.
Process topics use `bee.app.*` and change with all senders and receivers in one
deployment followed by a full node owner restart. Topics are not persisted.
Application principals retain `bee.application:<workspace_id>:<instance_id>`
because Threads records and command receipts persist that identity. Workspace
thread bindings also store it, and recovery compares it with stored memberships.

Workspace database schema, registry revision, app revision and app resume schema
are different version domains. Apps own interpretation of their opaque state;
workspace migrations must not rewrite it. The current broker rejects a changed
resume schema rather than attempting a cross-schema migration.

Wippy registry history in `.wippy/registry.db` is separate from workspace state.
Runtime overlays do not make this envelope a code store. Durable threads need
their own append/read/subscription owner and tables; do not put their event log
inside the desktop JSON. Future publication records, resource bindings and shared
catalogs likewise need explicit owners. Sharing a local SQLite file would not
grant cross-owner SQL access or provide synchronization between machines.

The desktop contract specifies the client identity
and client layout split for future mixed-workspace tabs. The storage identity
exists and the app SDK exposes workspace-qualified logical view references.
Desktop snapshots preserve workspace identity for newly opened windows.
Client layout separation and admitted local attachments are implemented. Mixed-workspace
composition and remote routing remain unimplemented.

## Layout reference migrations

Placement migration 8 moves the Git worktree binding and its saved `plan`,
`setup` and `cleanup` callable identities to `bee.git.worktree` and
`bee.git.worktree.binding`. It changes only those top-level record fields and
exact worktree setup/cleanup markers. Nested preparer state, attempt identities,
positions and unrelated evidence remain unchanged. The migration runs before
recovery reads the plans; a restarted sweeper uses the new callable targets
and recognizes cleanup completed by the previous build. If old and new binding
keys collide for one attempt, the owning migration transaction refuses the
collision and preserves both records with the migration unapplied.

Sync migration 8 and Gateway migration 16 move complete registry-reference
scalars for the layout changes in their owned projections/events/receipts and
surfaces/active selections/trait grants. Embedded prose, actor instance strings
and escaped opaque JSON remain unchanged. Existing migration SQL and checksums
are preserved; each owner applies its additive migration through `bee.persist`.

Placement migration 9 moves the concrete worktree binding to
`bee.git.worktree.binding:binding` without rewriting its opaque cleanup state.
It also moves complete reference scalars in stored attempt requests/grants.
Sync 9 and Gateway 17 apply the component-root identity map to their serialized
reference records; Gateway also moves its saved policy reference column.
Resources 4 and Credentials 7 update resource roots and credential
source/materializer identities in their own columns. The new migration blocks
cover the cumulative map, including pre-refactor resource and credential IDs.
These additive migrations
preserve the earlier SQL/checksums, caller digests, incarnations and grant data.
The complete identity map is `build/layout_identity_moves.json`; the root-only
follow-up is `build/layout_root_moves.json`.
