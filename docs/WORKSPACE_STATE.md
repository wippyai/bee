# Workspace state and application restoration

This describes the implemented version-1 store, not the future resource catalog.
The workspace host alone opens `bee:workspace_db`. Its source-development default
is `.wippy/workspace.db`; `BEE_WORKSPACE_DB` selects another file. The standalone
executable uses its application state directory by default and preserves the
caller's working directory for native commands. See the [launch instructions](../README.md).
Each database has a durable opaque workspace ID in the separate
`workspace_identity` table. Selecting a project folder does not create an
authorized filesystem binding.

## Persisted values

The store has a checked migration ledger and one versioned JSON envelope, with a
generation used for compare-and-swap writes. See [storage](STORAGE.md) for SQL
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
receipt preserves later edits across repeated boots. See [the desktop contract](DESKTOP.md).
Host recovery retains resume records for failed or incompatible restores. Runtime PIDs, launch tokens,
TTY mounts and native resources are recreated, never stored as authority.
PID strings may repeat across runtime boots.

## Application contract

`meta.application.resume_schema` and `restart_policy` declare support. The policies
are `never` (default), `automatic` and `manual`. Automatic instances reopen at
boot in saved order; manual instances resume when opened. Restored launches carry
`resume_schema` and `resume_state`, stable logical IDs and fresh capabilities.

`client.checkpoint(launch, json_string)` returns a queued request ID. Only a
successful `bee.application.checkpoint_result` means database commit. The broker
checks sender, identities and token; the workspace validates and writes the
envelope. One pending request per app is retained; supersession and timeouts have
explicit outcomes. A timeout is not proof the transaction never committed.
See [application contracts](APPLICATION_CONTRACTS.md) for exact messages.

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
