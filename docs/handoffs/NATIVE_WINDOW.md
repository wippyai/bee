# Managed native window implementation boundary

Status: implementation plan, not a callable production interface. The current
public Claude/Codex commands still run ordinary native Terminals. Structured
native continuation is checkpoint d4e84b7; it does not supply an interactive UI.

The ordinary user flow is **Agent → Codex** (or Claude), opening the native
harness UI. The selected profile supplies local or Docker placement, flags and
Bee MCP configuration behind that flow. Docker remains an unimplemented option
until its separate placement acceptance exists.

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

## Shared setup checkpoint

The native runner now delegates HOME/configuration, credential and gateway
materialization and working-directory resolution to the private placement
`materialization` library. It runs after the same starting transition; the
runner still owns gateway retirement and child execution. The helper returns a
minted binding identity even on a later preparation failure, so the runner can
revoke it. No credentials enter a durable record or a public reply.

MCP endpoint declarations may be supplied through the MCP component's governed
registry overlay. Host activation still owns listener binding, actual address
publication and authorization. This activation path is planned, not implemented
by this extraction.

Host-selected options are implemented: Claude `model` and `effort` in existing
prepare options; Codex `reasoning_effort` in its provider declaration. Both retain
existing defaults when omitted. The Codex CLI probe completed two turns with
`model_reasoning_effort = "max"`, and both persisted turn contexts recorded
`max`; this validates CLI configuration consumption, not provider support for
all model/effort combinations. Evidence:
`/tmp/bee-codex-effort-cli-20260911.log`.

Launch admission decodes bounded prompt text, including an empty string. After
resolving the definition and selected mode, it refuses an empty structured-launch
brief before resource grants or credential projections. A window may open with
no prompt, matching the ordinary native UI. Profile compatibility and host
permissions are still required; this does not itself enable PTY admission.

The structured carrier now refuses window mode and non-stream-json protocols
at both open and resume, before any thread, placement or gateway I/O. Planning
remains shared; execution must use the transport owned by the selected profile.
The native PTY facade is under separate acceptance and is not activated in the
production catalog or global executable.

Shared attempt preparation now admits the action, prepares and claims its
thread attempt, admits any gateway binding, and records placement intent. It
returns the carrier epoch and binding identity without requesting a turn or
starting a transport. Structured open reuses that preparation and retains its
existing turn/checkpoint/start sequence. Window activation remains pending.

## Installable application boundary

The managed native window belongs to the harness package, consuming the public
application lifecycle and the terminal grant supplied by the broker. It must
not add driver selection, credentials, MCP configuration or placement storage to
core client/session/presenter code. Ordinary users choose Agent → Codex; the
host-selected profile supplies the admitted implementation and options.

`build/modules.json` separates harness, drivers, gateway, resources, credentials,
threads and native placement. This is assembly ownership, not independent
installation evidence. The harness currently names `bee:workers` in launch
admission and the host policies `bee:carrier_policy` and
`bee:launch_spawn_policy` in its manifests. Independent installation must bind
those host dependencies explicitly and prove that missing bindings refuse to
run. Package metadata cannot choose or widen its own permissions.

The installation owner must resolve and measure the dependency closure, review
capabilities, activate on the selected destination, and report its committed
result. Hive transports that authorized request and content; the destination
owns activation, resource mappings and credentials. No source-machine paths,
credential values or terminal grants become portable installation data.

The install acceptance must boot a minimal host with the package's declared
requirements, refuse a missing requirement, install/update through governance,
and launch on a second Bee through Hive with destination-local resource and
permission checks. Removal must retire services and bindings without deleting
application data. These checks remain pending in the installation lane; the
native window fixture and bundled build do not substitute for them.
