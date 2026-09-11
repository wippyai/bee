# Managed native window implementation boundary

Status: implementation plan, not a callable production interface. The current
public Claude/Codex commands still run ordinary native Terminals. Structured
native continuation is checkpoint d4e84b7; it does not supply an interactive UI.

The requested window renders the native Claude Code or Codex PTY. A managed
window owner, spawned by the application broker with the sole terminal grant,
will own exactly one native child and its terminal session. Physical clients
attach to that application's retained viewport through the existing broker.
F12 and client detach must neither re-execute the command nor settle its attempt.
An explicit application close stops the child through the placement lifecycle.

## Existing boundaries that constrain implementation

- `src/core/applications/broker.lua` creates the viewport and grants terminal
  authority to the app actor it spawns. It tracks that actor's readiness and exit.
- `src/apps/console/app.lua` creates an unstarted PTY and calls
  `attach_terminal()`. The returned native terminal session consumes child
  ownership and handles input, resize and completion.
- `src/placement/native/service.lua` currently starts an independent runner on
  the selected worker host. That runner has no application terminal grant.
- `src/placement/native/runner.lua` performs admitted resource and credential
  materialization, records execution and cleanup, and presently uses pipes.
  Its owned setup and cleanup must be shared with the managed PTY path; spawning
  an ordinary Terminal after that would create a second unmanaged child.
- `src/harness/catalog/classify.lua` admits stream-json profiles only. Do not
  declare PTY compatible until its actual carrier and lifecycle are accepted.

A local probe against the selected recovery runtime found that a `funcs.call`
executes with a different process PID. Matching screen dimensions do not prove a
function can consume another actor's terminal grant. The failed shortcut is
recorded in `/tmp/bee-function-terminal-probe-r2-20260911.log`; it is not a runtime
bug or a request to change runtime semantics.

## Required implementation and acceptance

The managed window entry must integrate with broker launch/readiness/close while
remaining the placement owner of its single child. Share resource resolution,
private HOME and generated configuration, executable measurement, credential
projection, execution identity and cleanup with native placement. Keep those
permissions on the explicitly admitted execution component. Ordinary apps and
client presenters gain neither placement database nor credential authority.

Resolve the authenticated requester's launch definition and typed profile options
before execution. Preserve pinned definition, driver and policy identities in the
attempt. Model and effort options use the existing host-selected configuration
path; user overrides need explicit admission. MCP and traits retain scoped
request/context/security identity. A listener address is host-selected and must
be OS-assigned, not a globally fixed port or a caller-selected credential sink.

Prove real native interactive frames, keyboard and wheel input, resizing, two
windows with isolated homes/configuration, retained PID across F12 and physical
client detach/rejoin, explicit close cleanup, denied foreign input and stale
replies. Hook delivery and thread subscriptions must not imply native input
readiness or exactly-once keystroke execution. Thread records remain independent
of filesystem resources. Docker is a separate placement implementation; its
mount and synchronization contract remains to be discussed.

Reference only: `../bee-legacy/os-harness/src/window.lua` and the legacy native
driver implementations demonstrate window versus structured session behavior.
No legacy code or filesystem path becomes a shipped dependency.
