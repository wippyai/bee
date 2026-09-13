# Retained Agent configuration: verified filesystem boundary

The next recovery gap is replacing host-generated configuration for a new attempt
while keeping its provider conversation files. Current Bee admits replacement
only after the previous native process group is independently absent and cleanup
is complete. `homes.write_protected` then permits only byte-identical replay;
Codex/Agy changes to endpoints, tokens or hook configuration therefore refuse
recovery instead of overwriting the retained files.

## Current runtime surface

Read against `~/wippy/wippy` on September 13 (read-only; the shared checkout has
unrelated cluster/stream/supervisor changes):

- `api/fs/fs.go`: Go `FS` already includes `Lstat`, `OpenFile`, `Rename`; files
  expose `Sync`.
- `runtime/lua/modules/fs/fs.go`: Lua exposes `open`, `stat`, `mkdir`, `remove`
  and file reads/writes. There is no `rename` or `lstat` method. `open` supports
  `r`, `w`, `wx` and `a`.
- `runtime/lua/modules/fs/file.go`: Lua file handles already expose `sync`.
- `service/fs/directory/fs.go`: the directory backend delegates to `os.Root`.
  This confines access to the filesystem root; it does **not** reject all links
  or confine access to one session below a shared placement root.

A disposable Go 1.27 probe proves that `Root.OpenFile` with exclusive creation
follows `session-a/config -> ../session-b` inside the same root and creates the
file in session B. This is a fact about the primitive, not a demonstrated Bee
exploit: Bee currently refuses pre-existing configuration parents. Evidence:
`bee-evidence/0912/retained-config-root-symlink-proof.log`.
The earlier suggestion that `os.Root`'s internal use of `O_NOFOLLOW` establishes
non-following application semantics was incorrect. A separate `Lstat` followed
by an ordinary path operation also leaves a check/use race.

## Required behavior before enabling replacement

Keep authority in the existing admitted placement and filesystem components.
The operation must publish a whole bounded file under the selected session home,
with an exclusive temporary file, checked write/sync/close, atomic replacement,
and explicit handling of failure after publication. It must not follow a changed
parent into another session. Root privacy and regular-file expectations must be
checked at the operation boundary, not inferred from registry creation metadata.
No remove-then-create interval or general shell command is an acceptable substitute.

The remaining design decision is how the existing filesystem provider supplies
a handle confined to the selected session/parent for the entire operation. Merely
exposing `rename` and `lstat` to Lua does not prove this. The operation should be
optional for providers that cannot supply the guarantee and refuse explicitly;
it must not claim atomicity or crash durability on every filesystem backend.
File-content publication and parent-directory durability are separate outcomes.

Bee keeps the admitted configuration template and predecessor checkpoint until
replacement and new startup are acknowledged. Retry must distinguish a completed
publication from an uncertain durability result and must never replay the user's
prompt. Configuration ownership does not authorize edits to conversation files.

Acceptance needs ordinary replacement, missing target, changed/nonregular target,
symlinked/swapped parent, sibling-session isolation, denied/read-only filesystem,
short write, file-sync/close failure, rename failure, post-publication directory
sync failure, concurrent attempts, crash/restart, and unchanged provider session
files. Real Codex/Agy continuation must then prove fresh gateway credentials and
no duplicate native process or prompt replay.

No runtime change or new callable API is introduced by this handoff. The current
open runtime PR list has no filesystem replacement proposal. Any implementation
belongs in a runtime PR assigned to Rodrigo (`skhaz`), with existing ownership
preserved; do not modify the dirty shared runtime checkout.
