# Workspace state and application restoration

This describes the implemented version-1 store, not the future resource catalog.
The workspace owner alone opens `bee:workspace_db`. Its default local file is
`.wippy/workspace.db`; `BEE_WORKSPACE_DB` selects another file. The launcher runs
from the Bee checkout directory. Selecting a project folder does not yet create
a stable workspace UUID or an authorized filesystem binding.

## Persisted values

The store has a checked migration ledger and one versioned JSON envelope, with a
generation used for compare-and-swap writes. See [storage](STORAGE.md) for SQL
ownership and integrity checks. The envelope is bounded to 2 MiB.

| Envelope field | Contents |
|---|---|
| `version` | `1` |
| `desktop` | Validated scene, tabs and appearance preferences |
| `applications` | At most 16 opt-in resume records |
| Each resume record | `id` (view), `instance_id`, `definition_id`, `resume_schema`, `restart_policy`, `resume_state`, optional `window` |

App state is a JSON string bounded to 64 KiB. There are no persisted per-app
checkpoint sequence numbers, pinned definition versions or workspace UUIDs in
this envelope. Runtime launch values include revision information, but recovery
resolves the admitted definition available at boot and checks its declared
resume schema. An installer must not mistake this for version pinning.

The workspace stores committed scene changes, not each drag preview. It retains
resume records for failed or incompatible restores. Runtime PIDs, launch tokens,
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

[Workspace attachments](WORKSPACE_ATTACHMENTS.md) specifies the proposed identity
and client layout split for future mixed-workspace tabs. That identity and remote
attachment protocol are not implemented by the current envelope.
