# Node descriptions

This owner stores editable `display_name`, `description` and string `labels`
beside the runtime's native node identity. The identity is read from the runtime;
metadata cannot change identity, trust, permissions or measured capabilities.

`describe({})` returns the current description and revision (zero before the
first write). `update_metadata` replaces the complete description using an
`expected_revision` and caller-scoped `idempotency_key`. The shared sync store
commits its projection, ledger event and retry receipt in one SQLite transaction.
Replaying a key preserves its original receipt; different input conflicts.

`snapshot({})` and `read_after({cursor,limit?})` expose the `node.description`
feed through the shared sync protocol. Cursors belong to one owner and feed.
Native node identity is the owner; a changed native identity does not silently
take ownership of the previous node's records.

The host links `target_db` and grants `bee.node.read` or `bee.node.update` on
the native node ID. Published methods retain the authenticated caller and attach
only the private store access needed for their implementation. The metadata
trait grants no authority. Ordinary applications cannot open the database.

This is SQLite-backed descriptive state. It does not publish registry entries,
install packages, activate overlays or replicate decision authority. Remote
exposure must be admitted by the existing Hive supervisor; the presence of the
methods in the registry does not expose them to a peer automatically.
