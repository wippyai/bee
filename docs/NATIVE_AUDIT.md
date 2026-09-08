# Native distribution audit

Reviewed September 7, 2026. Scope: Wippy Builder, the runtime application host,
Bee's native module and bootstrap, SDK documentation, release workflows, and UI
ownership/import boundaries. Builder and Bee repositories are currently private.

## Findings addressed

| Finding | Change | Verification |
|---|---|---|
| Notification backend interprets a trailing `...` as recursive syntax | Pass directory names with a trailing separator | Real event test for `literal.../file.txt` |
| Pack output could name its own build manifest | Reject the overlap before running the pack command | Regression checks the error and unchanged manifest |
| Bootstrap inherited Git repository handles and checkout behavior | Isolate Git environment, disable hooks/line conversion, reject modified or ignored checkout files | Run Git with foreign `GIT_DIR`, work tree and index settings |
| Watcher overflow behavior was underspecified | Document native buffer, runtime retention limits, channel closure and reopening | Checked runtime subscription and overflow implementation |
| Documentation mixed design instructions with implementation status | Describe ownership, callable APIs, tested behavior and remaining work directly | Manual review of promptmap leads and source references |

The selected builder revision is `6e2852f063f833fdcee9b6a2f63ccee6d8523e01`.
The native component is pinned to
`v0.0.0-20260908020612-39e56a73d8d4`.

## Architecture

The builder's generated entry point calls runtime `application.Run` and passes
native factories as `boot.Component` values. Source tools use
`cmd.ExecuteWithOptions`. The runtime owns deployment loading, Hub resolution,
command dispatch and shutdown. Builder owns build inputs and release artifacts.

Native module registration uses Wippy boot dependencies, `ModuleDef`, typed
manifests and the dispatcher. The watcher resolves an admitted filesystem
resource, checks `fs.get` and `ioevents.watch`, and routes events through runtime
subscriptions. Its engine integration is coupled to the selected runtime revision.

Bee separates workspace, session, broker, presenter, shared UI and application
processes. Registry imports preserve those identities independently of directory
names. The promptmap directory graph reported shared UI imports as layering
violations; those imports are allowed by Bee's development contract. Its
desktop/protocol directory cycle combines separate library dependencies. Lua
lint and the production registry/import checks passed.

## Validation

- Builder: `make check` — race tests, vet and formatting checks.
- Bee release worktree: full `make check` using the native toolchain — source and
  pack checks, real PTY interactions, persistence and recovery.
- Shared UI workspace: `make lint test` — typed lint and 85 unit tests.
- Native component: `make native-check` — bootstrap checks, race tests, vet,
  typed Lua permission denial and filesystem event delivery.
- Standalone: `make native-tools standalone` followed by
  `make native-binary-check` — empty-directory boot, Settings recovery, Terminal
  execution and F12 presenter replacement.
- Linux Docker: native Lua integration with a host-written bind mount, non-root
  user, no network, all capabilities dropped and `no-new-privileges` enabled.
- Workflow syntax: actionlint v1.7.7 passed for Builder and Native Bee.
- Runtime PR 668: Linux, Windows, lint, native Lua and CDC GitHub checks passed
  at `b8c7a932`; the subsequent audit commit changes comments and documentation.

The local rebuilt executable, provenance and logs are in `dist/native-audit/`.
The Docker check exercises the native module. Full Bee desktop acceptance inside
a container remains separate work.

## Remaining release work

- Review and merge runtime PRs 667 and 668; the current build carries patches.
- Stabilize the event SDK boundary currently using exported engine APIs.
- Add macOS, Windows and additional architecture acceptance. Docker Desktop
  filesystem mounts require separate testing.
- Complete upstream license notices before stable distribution.
- Implement Bee Hub publication and in-app installation. Update lint currently
  validates exports and Lua types; semantic native-version requirements remain
  unimplemented.
