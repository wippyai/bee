# Retained Agent configuration: verified filesystem boundary

Source now replaces host-generated configuration for a new attempt while keeping
provider conversation files. A new retained-session attempt is admitted only
after the previous native process group is independently absent and cleanup is
complete. `homes.publish_configuration` uses the optional native atomic operation
for the persisted delivery files; `homes.write_protected` keeps its immutable
replay contract for other callers. The global installation checkpoint remains in
[GLOBAL_BUILD.md](GLOBAL_BUILD.md); source implementation is not proof that a
real provider conversation has resumed after restart.

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

The runtime proposal pins verified parent directory handles for the entire
operation. Merely
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

## Runtime proposal and validation

[Runtime PR #744](https://github.com/wippyai/runtime/pull/744), assigned to Rodrigo
(`skhaz`), adds optional `AtomicWriteFS` and Lua `fs:writefile_atomic(path, content)`.
It is not merged. The source manifest includes its checksum-pinned patch; the
installed runtime is tracked separately in GLOBAL_BUILD.md. The isolated runtime
head is `5e76e3c4e1`; the shared runtime checkout was not modified.

The Linux/macOS directory implementation holds verified parent handles, publishes
through an exclusive temporary file and reports post-publication directory-sync
failure separately, with `err:details().published == true` so the caller does not
parse error text. Lua accepts strings up to 8 MiB, requests mode `0600`, and
uses fixed provider-error messages. Unsupported providers refuse explicitly.
This is whole-file publication, not compare-and-swap or a session authority grant.

Final filesystem API, directory and Lua race suites pass; repository-pinned lint
reports zero issues. Coverage includes real Lua/backend publication, parent
replacement, concurrent readers/writers and injected publication failures.
Darwin arm64 and Windows amd64 directory packages cross-compile; macOS has not
been executed and Windows explicitly returns unsupported.

Bee's source consumer now replaces retained host configuration. Real-provider
recovery and crash/restart acceptance remain separate from the filesystem and
placement tests.

## Consumer review

Placement already admits one unfinished attempt per owner/session. The structured
runner now joins the window runner in claiming `intended` as `starting` before
materialization; a duplicate cannot replace `runner_pid` or create files. The
regression fails on the old runner (it starts the duplicate) and passes on the
corrected runner alongside all 845 unit tests.

The consumer replaces only persisted, host-rendered `delivery.files` paths in a
retained home. It rejects overlap with login bytes, the login source marker and
provider initialization files. Conversation files remain separately owned.
Before materialization and each publication it checks that the attempt is still
`starting` and its recorded runner is the current process. The existing session
admission and cleanup rules remain; the filesystem operation grants no session
authority.

Publication is atomic per file, not across the delivery list. A later failure
refuses startup without claiming that earlier files were rolled back. A
published-but-unsynced result records `configuration.uncertain` and leaves
execution uncertain, retaining the session holder. It requires inspection before
any further attempt. Startup failure does not replace the predecessor checkpoint
or replay its prompt.

## Consumer evidence

The source candidate passes all 850 unit cases, including actual publication of
changed host configuration across two native attempts, missing targets, nested
parents, path/link/nonregular/root-mode refusals and unchanged login/conversation
sentinels. A fault-injected instance of the actual materialization library uses
the real placement store to prove post-publication uncertainty holds the session
and a stale runner creates or publishes nothing. An earlier test wrapper did not
execute those two cases; only the corrected 850-case run is evidence for them.

The standalone candidate passes loopback-only offline boot/restart/reconnect
(warm reconnect 0.216s) and the existing Claude fixture restart gate. These do not
prove actual Codex/Agy conversation recovery. The prior source branch's full
`make check` failed in `control_delivery.py`: injected structural failure reached
the terminal as `Desktop dependency exited` instead of the required original
delivery reason. A focused repeat fails the same way; that separate desktop gate
is still unresolved. No claim of a fully green release is made here.
