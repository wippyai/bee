# Managed native window implementation boundary

Status: native managed Agent windows are implemented and installed; managed
Docker windows remain under integration. The constructor routing below is source
work and is not installed globally yet.

The ordinary flow is **Agent → Codex** (or Claude/Agy). A profile selects the
harness, placement, options and MCP scope. The broker gives the Agent process its
terminal grant. That same process handles the picker, admission, hooks and window
lifecycle; selecting Docker does not create another application manager.

`bee.harness.window:runtime` receives a typed constructor table from the process
entry, keyed by the native and Docker placement bindings. Only the host-admitted
plan selects the constructor. Missing constructors refuse before attempt
preparation. Request data cannot supply callbacks. The current attachment epoch
is passed to the constructor; native placement verifies that it matches the
recorded recipient and generation before starting its child.

`bee.placement.docker:window` attaches an already-started container using the
placement service's checked identity. Its registered library loads without a
daemon connection; actual use requires the separately configured Docker service
and native attachment permission. It neither creates containers directly nor
owns another store. Terminal completion is not container exit: reconciliation and
cleanup remain placement operations. Public Docker launch, scoped attachment,
restart recovery and session release still require integration acceptance.

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

All ordinary app bindings retain the subsystem-store deny. Runtime tests attempt actual database opens with a broad allow
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

`BEE_CLAUDE_BIN=/absolute/claude BEE_CODEX_BIN=/absolute/codex make
managed-provider-window-check` runs both actual provider UIs through broker
admission and their sole PTYs. It checks keyboard input, resize, preserved UI
state on rebind, one cancelled receipt per provider, arguments without an
injected prompt, distinct newly initialized private homes and host-generated
Codex configuration. The probe supplies no credentials, submits no turn and
uses only a loopback model endpoint. It reports each actual executable version
alongside its declaration version; the observed Claude 2.1.268 and Codex
0.154.0 starts do not certify the older 2.1.265 and 0.153.4 declarations.

This is explicitly a direct-process/EOF fixture policy. The refreshed runtime
includes process-group supervision and `Process.pid()`/`Process.done()`. However,
`attach_terminal()` consumes an unstarted process: its returned terminal session
exposes no execution PID or verified process-group cleanup outcome, and the
consumed process cannot supply that identity. Placement therefore cannot yet
prove managed-window cleanup. The probe asserts that terminal exit leaves cleanup
pending. This is a terminal ownership/cleanup contract gap, not a missing generic
process API. Production cleanup, authenticated turns and physical-client/F12
retention remain separate gates; production requirements were not relaxed.
See [the runtime cutover](RUNTIME_MAIN_CUTOVER.md) for current toolchain evidence.

## Standalone harness acceptance

`make harness-module` stages the harness and its declared imports
in a small host. These imports include native
placement materialization and storage helpers used by the managed window; no
desktop owner, thread service, placement operation or running placement service
is loaded. Lint and boot pass against both staged source
and a source-free pack. The catalog is empty on an empty host, a linked process
host reaches request validation, and an unlinked host refuses before admission.
Host policies in this fixture deny execution. This
is standalone composition acceptance, not successful carrier execution, package
installation or Hive activation; those still need the full dependency owners.

## September 11 desktop acceptance follow-up

The full client-desktop source/pack suite passes on the managed-window source:
independent displays and appearance, shared-store isolation, retained Terminal
reconnect, F12, all three display-transfer cases, supervisor failure handling,
and thread status retention. Launcher, recovery, Approvals inbox, Hive Manager
and Timeline checks also pass. The transfer fixture now waits for the exact
retained shell PID marker in the destination frame before typing; committing
layout alone does not establish presenter readiness.

The preceding full foundation run stopped on missing post-transfer output.
During focused validation, client setup also refused intermittently before
transfer. Its diagnostic now includes the request and error code. The passing
follow-up does not explain or establish a fix for that separate rejection, and
is not a single uninterrupted full foundation run or a global installation.
Production process-group cleanup, authenticated provider turns and automatic
project-node Hive joining remain separate acceptance gates.

## Window checkpoint and hook delivery

The window commits its pinned carrier checkpoint before opening the native child.
This checkpoint records driver, profile, plan, carrier epoch and any retained
session or gateway binding identity. It contains no provider credentials and
does not create a logical turn or a successful result.
After that commit, placement attaches the attempt to the window actor at the
prepared carrier generation. Gateway validation requires this attachment before
the PTY may start. An unconfirmed attachment refuses the child start.

While the PTY runs, the actor drives one asynchronous gateway or carrier call
alongside terminal input, lifecycle and completion channels. It validates the
claim's binding and epoch, decodes the bounded batch through the shared carrier
hook helper, commits observations, then acknowledges those exact event IDs.
A lost commit reply retains its request, key and expected revision. Missing or
mismatched revision evidence never starts the child or acknowledges a batch.
Permanent authority failures stop delivery with an uncertain outcome; transient
failures back off. A hook notification never settles an agent turn.

After PTY completion, the actor seals intake and resumes any pending commit or
acknowledgment before claiming the remaining batches. A confirmed seal followed
by an empty valid claim proves the queue drained. Deadline expiry cancels the
outstanding future and leaves the attempt uncertain; claimed rows remain for
reconciliation. Placement then finishes and revokes the binding. Explicit close
can record cancellation only when this drain completed. Cold application resume,
provider conversation restoration and public scoped MCP activation remain
separate acceptance gates.

`make window-hooks-check` runs an actual shell child through generated hook
configuration, HTTP admission, the window actor and the thread owner. The child
submits the same event twice; acceptance requires one committed observation and
gateway acknowledgement, with no invented turn records. A fixture delay in the
real claim operation checks responsive PTY input and graceful close while hook
delivery takes seconds. The disposable listener address is fixture configuration;
this does not establish public MCP port-zero discovery or readiness.
