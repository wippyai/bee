# Managed native window implementation boundary

Status: a private harness-owned actor and fixture acceptance exist; this remains
outside the callable production interface. The current public Claude/Codex
commands still run ordinary native Terminals. Structured native continuation is
checkpoint d4e84b7; it does not supply an interactive UI.

The ordinary user flow is **Agent → Codex** (or Claude), opening the native
harness UI. The selected profile supplies local or Docker placement, flags and
Bee MCP configuration behind that flow. Docker remains an unimplemented option
until its separate placement acceptance exists.

The private `bee.harness.window:app` actor is spawned by the application broker
with the sole terminal grant. It owns exactly one native child and terminal
session, reuses typed launch admission and shared attempt preparation, and
opens the PTY in its own actor so `attach_terminal()` consumes that grant. Its
broker launch argument is one strict JSON request; the authenticated workspace
is injected and callers cannot choose an environment or transport. Completion
is recorded as `uncertain`, except explicit application close, which records
`cancelled`. The application has no command metadata or public catalog route.

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
- `src/harness/catalog/classify.lua` matches batch/session profiles to
  stream-json and window profiles to PTY. This compatibility is separate from
  host activation, protected admission and provider-specific acceptance.

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
The native PTY facade has focused acceptance. Catalog classification recognizes
PTY only with window mode and stream-json only with batch/session mode;
`meta.test_support` grants no compatibility exception. No production PTY profile
is activated in the production catalog or global executable.

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
installation evidence. The harness links its carrier process host through `process_host` and refuses
a missing binding before admission. The bundled default is `bee:workers`. Its
manifests still name the host policies `bee:carrier_policy` and
`bee:launch_spawn_policy`. Independent installation must bind
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

Launch admission exposes one typed internal `admit_request` result containing
the resolved plan, carrier request and admitted identities. The external
`admit` method wraps the same result in its existing reply envelope, and
structured start consumes it directly. The managed app can reuse this path
without a second decoder or a separate authority implementation.

## Host admission of execution components

The broker continues to compose the same mandatory base, application boundary,
core spawn boundary and workspace/client-store deny. The host now lists the
ordinary subsystem-store deny explicitly in each ordinary application's
existing protected `policies` list. A reviewed execution component may instead
receive the precise placement policies it requires. No app metadata, profile
request or broker-specific execution flag selects this scope.

All ordinary app bindings retain the subsystem-store deny. Architecture checks
require it, and runtime tests attempt actual database opens with a broad allow
to prove the deny still wins. A component with placement permission can open
that store only; core stores remain denied even under a broad allow. The private
managed app is the reviewed execution component: its protected binding grants
only the carrier and placement policies needed for the one child, while the
broker still supplies the base, core and workspace-store boundaries.

`make managed-window-app-check` proves the fixture-only path through a real
broker: PTY input and resize, detach/rebind without restarting the child,
explicit close with revoked input, and exactly one cancelled attempt receipt.
A second case allows natural PTY completion and requires one uncertain receipt.
Neither path creates logical turns. It runs as part of `make check`. PTY completion
does not prove OS descendant cleanup; that remains pending in placement. It does not yet
prove a production profile, an Agent-to-Codex menu or command binding,
installer/Hive activation, or the full F12 and physical-client lifecycle. An
emergency process kill can still leave a prepared or running attempt for normal
placement reconciliation.

A future installer must review changes to the complete protected admission
policy set. With the current schema an omitted ordinary deny is a permission
change, not a self-declared component role; package metadata cannot authorize
that omission. Hive installation enforcement remains a separate acceptance gate.

Interactive PTY profiles may explicitly declare `answer_path: {strategy: none}`.
That declaration has no adapter and is rejected for structured batch/session
profiles. The managed-window fixture uses this shape, so its cancellation
receipt no longer depends on an unused provider answer adapter. This declares
absence of logical answer extraction, not successful completion from PTY exit.

Both bundled provider declarations now include a `window` profile using
`pty` / `native-window-1`, a private provider configuration home and no structured
answer extractor. Their existing structured default profiles remain selected.
These declarations describe the native UI path already generated by each
driver's launch code; no public launch definition selects them yet. Real provider
startup, authentication, scoped gateway configuration and physical-client
retention require their own acceptance before public activation.

Driver `Launch.argv` contains arguments only. Placement supplies the separately
selected executable once for both structured and PTY execution. The provider
launch builders previously repeated their program name in `argv`; native
placement would execute `claude claude ...` or `codex codex ...`. Direct provider
tests that replaced `argv[1]` hid the mismatch. They now prepend the executable
and preserve every argument, matching placement.

An empty window brief records the action description `Open <driver title> window`
in the thread ledger. The driver still receives the empty brief and sends no
prompt argument. This preserves nonempty thread content without inventing user
instructions for the provider.

`BEE_CLAUDE_BIN=/absolute/claude make managed-provider-window-check` runs the
actual Claude onboarding UI through broker admission and its sole PTY. It checks
keyboard selection, resize, preserved selection on rebind, one cancelled receipt,
arguments without an injected prompt, and a newly initialized private home.
The probe supplies no credentials and uses an unused loopback model endpoint.
It reports both the actual executable version and the declaration version;
the observed 2.1.268 startup does not certify the older 2.1.265 declaration.

This is explicitly a direct-process/EOF fixture policy. The current recovery
runtime refuses the production process-group requirement because the exec handle
exposes no PID. The probe also asserts that terminal exit leaves cleanup pending.
Production cleanup, authenticated turns, Codex UI and physical-client/F12
retention remain separate gates. Production requirements were not relaxed.

## Static harness isolation proof

`make harness-module` stages all harness entries and its exact reviewed static
import closure in a small host. The 28 external library entries include native
placement materialization and storage helpers used by the managed window; no
desktop owner, thread service, placement operation or running placement service
is loaded. Exact registry coverage, lint and boot pass against both staged source
and a source-free pack. The catalog is empty on an empty host, a linked process
host reaches request validation, and an unlinked host refuses before admission.
Host policies in this fixture deny execution. This
is a static composition proof, not successful carrier execution, package
installation or Hive activation; those still need the full dependency owners.
