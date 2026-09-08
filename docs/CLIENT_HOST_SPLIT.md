# Workspace host and desktop client extraction

Status: extraction in progress; a private TTY-free host actor is implemented and
tested separately from the current local desktop.
The existing desktop now uses `bee.terminal:display` for physical output, the
presenter's virtual viewport, boot/recovery frames and viewport replacement.
This owner-local library contains no application routing, database access or
process supervision. The new client can reuse it without moving the physical
output lease into the replaceable presenter. Normal desktop client launch remains pending.
The required behavior and native mesh boundary are in
[workspace attachments](WORKSPACE_ATTACHMENTS.md). Local Bee still combines the
physical terminal owner and workspace host. No headless profile exists yet.
The current wide-terminal header shows the workspace's short durable ID; it is
informational, not a workspace switcher. The generic idle "Ready" label is gone.
The runtime registry stores definitions/history separately from the workspace
application store and journal; none of those storage paths is a UI workspace name.

`bee.host:main` owns its broker, configured persistence, automatic app
restoration and checkpoint receipts. Its bootstrap is restricted by host context
and exact core-spawn policy. Its supervisor selects admitted client executions
and their open, close and control permissions; ordinary applications cannot spawn
the host or admit clients. The `host`
fixture opens and checkpoints without a physical TTY, detaches a view, stops the
host and proves stable workspace/view/instance identities on automatic restart.
The fixture selects the host's process and storage policies explicitly.
The private host accepts an optional second `database_resource` argument. Its
supervisor must grant that exact `bee.workspace.db:<name>` resource through native
policy; omission retains `bee:workspace_db`. Registry configuration owns the
underlying SQLite path. Separate hosts must receive separate resources/stores;
resource selection does not elect an owner or make shared writes safe.
It also sends a correctly addressed open from a different actor and verifies
that the unauthorized application never appears in the restored membership.

This private entry is not yet used by `bee` and has no public command or headless
profile. It admits private desktop clients and delivers catalog/live-view and
selected-question snapshots; normal launcher integration remains unfinished.
Each private desktop client owns its separate layout store.
Its supervisor is a stable owner, not a replaceable presenter; losing that
supervisor ends the host. Local launch still uses the existing combined owner.
Do not run both owners against the same database: generation checks reject stale
writes, but they are not host election or a multi-writer protocol.

### Private client admission

Only the bootstrapped supervisor may send `bee.host.client` with version 1,
request ID, workspace ID, exact recipient PID and `admit`, `detach` or `render`. Admission
requires explicit `open`, `close` and `control` booleans; optional `appearance`
defaults to false and permits client preference changes. The host monitors that
execution and supplies a fresh connection ID through `bee.host.admitted`, along
with `renderer`, `renderer_generation` and `renderer_pending`.
Requests must match both the actual sender and the connection ID; metadata does
not grant access. Changing permissions requires completed detach first.

Client requests use `bee.app.request`. The host isolates request IDs by connection,
forces targeted bind recipients to the supervisor-selected renderer and denies host recovery,
whole-workspace binding, unbind and shutdown. There are at most eight admissions
and 128 retained request routes; exhausted pending capacity returns `busy`.
Completed routes are evictable, so this is bounded correlation, not durable
exactly-once execution. Open replies omit resume state and mounts; targeted bind
returns the recipient-bound mount in `attached`.
Bind requests additionally require the current `renderer_generation`. Stale
generations return `stale_renderer`; a transition returns `busy`, and a cleared
renderer returns `unavailable`. Bind correlation includes the renderer generation,
so repeating a public bind ID after replacement cannot replay a retired mount.
Open/close correlation remains scoped to the unchanged client connection.

Admitted clients receive `bee.host.reply` containing `{version, reply, views}`.
`reply` retains the application result shape; `views` is the complete qualified
inventory at that result. The public application protocol and supervisor's
`bee.app.reply` route are unchanged. The snapshot costs at most sixteen view
descriptions per operation result and avoids another retry queue or polling loop.
Clients compare revisions across inventory and result channels: a newer removal
prevents a late open result from selecting a dead app, and newer titles prevail.

Detach disables further requests before revoking grants. A successful
`bee.host.client_result` follows revocation and monitor removal. Failure retains
the disabled admission for retry. Execution exit initiates the same cleanup;
application processes remain alive. The `clients` fixture proves two actor
clients with equal public request IDs, stale-grant denial, permission replacement
rules, fresh connection IDs, automatic exit cleanup and retained native shell
state in source and pack. These actors are not independent desktop sessions yet.

### Private host inventory

Successful admission delivers `bee.host.catalog` and `bee.host.views`. Each is a
complete version-1 snapshot with `workspace_id`, `connection_id`, `revision` and
`items`. Catalog and live-view revisions advance independently. Clients must
authenticate the host sender, check both identities and reject stale revisions;
the private inventory library supplies strict payload decoders.

Catalog items are public application descriptors. Live items contain only the
workspace, view, instance and definition IDs, title and optional icon. They omit
execution PIDs, mounts, checkpoints and permission policies. Admission permits
this discovery; observing an item does not grant control or a terminal mount.
The live list is bounded to 16 views and excludes saved applications that are not
running. Joining clients receive existing views; opens, title changes and exits
publish updated snapshots. Catalog changes do not repeat startup restoration.
Detach fences publication immediately. A rejected delivery initiates the same
grant-revocation path as other client delivery failures.

Source/pack actor tests cover joining after another Terminal opened, observing
an application's title and removal, fresh snapshots after re-admission, and no
new inventory after detach. Inventory delivery is implemented in the private host;
the current combined desktop has not switched to these streams yet.

## Private desktop client acceptance

`bee.client:main(owner, host, workspace_id, database_resource, initial_application?, options?)`
now runs an independent desktop against one admitted host. Bootstrap requires
the supervisor's `bee.client_owner` context. The supervisor supplies desktop
permissions, `bee:client_spawn_policy` and an exact client-database grant; ordinary
apps cannot spawn this entry. There is no public client command yet.
The optional version-1 bootstrap options carry `arguments` for the initial
application and a boolean `fullscreen`. Arguments use the shared bounded decoder
and are forwarded as literal values. Fullscreen applies to the correlated initial
open result, without toggling an already-fullscreen saved tab back to floating.
Source/pack acceptance checks both literal argument delivery and saved fullscreen
state. Normal command aliases continue through the combined launcher until migration.

The actor owns its physical display adapter, layout store, session and presenter.
Its selected targets retain full workspace/instance/view identity, with separate
local tab keys. It observes the host catalog and inventory but selects only saved
targets or its own successful open requests. Presentation copies use local tab
keys; requests to the host retain native target IDs. Pending operations and bind
requests are bounded, and bind replies are fenced by renderer generation.
Initial catalog/view channels remain queued until admission supplies the connection
identity. Session projections preserve pending target records; only a correlated
removal acknowledgement can retire one. Duplicate qualified targets are rejected
even when their local tab keys differ. Graceful exit asks the session for a full
snapshot, committing commands already forwarded by the client before closing its
store. This wait has a one-second failure deadline, not a fixed exit delay.
It does not yet fence presenter input or commands still queued at the client;
that final input-drain protocol remains an acceptance requirement.

The supervisor receives `bee.client.ready`, admits that actual execution, then
receives `bee.client.renderer` when its presenter is ready. It selects that exact
renderer through the existing host `render` operation. F12 repeats this handoff
with a separate viewport; the old renderer stays alive until revocation finishes.
Repeating the active renderer/generation notification does not schedule new binds.
Startup and the event loop share cleanup of acquired stores, displays, children
and subscriptions; the display adapter also releases a partially initialized surface.
The session accepts a validated initial layout from its authenticated owner.

`tests/client_desktop.py` exercises two real desktop actors in source and pack,
independent screen geometry and selected tabs, native Terminal input, F12, client
exit without stopping the Terminal, and fresh-client reattachment using the saved
layout and the same live shell variable. Ctrl+Q detaches this private client;
it does not negotiate shutdown of the host's applications.
Trusted bootstrap may instead select `quit_mode = "supervisor"` in its final
version-1 options record. Keyboard and menu quit then send `bee.client.quit` to
the bootstrapped owner and keep the client alive. Only that owner can send
workspace-qualified `bee.client.control` messages: `state` supplies or clears a
validated global shutdown confirmation, while `exit` saves the committed client
projection and begins cleanup. `bee.client.shutdown_answer` returns the exact
question identity and decision to the owner. `bee.client.exit_ready` acknowledges
the final save; actual process EXIT establishes termination. Ordinary client
admission does not grant host shutdown authority.

For local runtime exit, `save` first commits the final projection and responds
with `bee.client.saved`. The client retains its display while consuming only
supervisor control and process lifecycle events. It ignores later host removals
and scene changes, preserving the saved restart layout. Host exit during this
phase does not release the display. The supervisor finishes host cleanup before
sending `exit`; owner/session/presenter failure still ends the client. Repeated
`save` requests acknowledge the already saved state without replaying queued edits.

The fixture exercises supervisor quit through the actual host and broker:
forwarded shutdown confirmation, cancellation, a fresh confirmation, accepted quit,
client save, completed host cleanup, explicit client exit, and preserved saved tabs.
It matches the broker's quit
reply to the accepted question ID. This proves the actor protocol; the public
local launcher still needs to perform that coordination.
The same source/pack fixture checks guarded Terminal close, confirmation isolation
between clients, F12 with a pending question, cancellation retaining the shell,
accepted close after client reattachment and stale-instance close rejection.

The fixture also opens Settings through Start and verifies that a theme change
persists to that client's store without changing the other client's preferences.
The host requires an explicit `appearance` admission grant for changes; shared
producer page defaults remain workspace-owned. The same source/pack fixture
verifies a fresh Settings write after F12 and denial for a second client without
the appearance grant. Reading current client preferences does not grant writes.

This entry is still incomplete: it has no mixed-workspace composition, no automatic migration from the
old workspace desktop, and no public launcher. Presenter exit retains the last
physical frame with F12 retry. Host/session loss or admission failure ends the
client; supervised renderer failure supports explicit retry
as described below.
These limitations are why normal `bee` continues to use
the existing combined owner.

## Named supervisor endpoint

### Private local launcher topology

The runtime's physical `tty.port` context key is deliberately non-inheritable.
A viewport grant is a virtual producer capability, not a way to transfer the
existing physical port. Keep the terminal entry execution as the desktop client;
it starts a TTY-free local supervisor, which starts and owns the workspace host.
The supervisor admits the entry client and selects its presenter through the
same private host protocol exercised by the fixtures. No second physical display
adapter or forwarding compositor is needed.

`bee.client:local(database_resource, initial_application?, options?)` constructs this topology
using `bee.launch:supervisor`. It has no public command metadata. The terminal
fixture supplies an exact client-store binding and narrow spawn/database policies.
Source/pack acceptance verifies physical-terminal boot, native execution, F12,
quit cancellation and coordinated exit without a second compositor.
The entry paints the existing boot logo before starting its supervisor and hands
the same display to the client. A monitored supervisor exit during startup reports
immediately and restores the terminal, without waiting for the startup deadline.
Ctrl+Q remains responsive while waiting for host readiness; startup does not
depend on a presenter to accept exit. Source/pack tests cover a stalled supervisor.
Private `bee.client:local_command(database_resource, name?, ...)` accepts the
existing desktop command forms: empty desktop, registered handler, or explicit
application ID with an optional secondary shortcut target. Ctrl+N opens the first
application; Ctrl+P opens the second, which does not launch at boot. Those targets
survive presenter replacement. Registered handlers preserve literal arguments and
open fullscreen when declared. `bee.client:local_application(database_resource,
application, ...)` accepts an explicit application ID and literal argument list,
matching `bee-app`. Source/pack acceptance checks all these forms. Public command
wiring still uses the combined entry.

`bee.launch:bootstrap` owns local startup and returns the display and its single
native input channel to the desktop in the same execution. It contains no window,
session or application routing. The separate supervisor actor remains TTY-free.

Before replacing normal launch, preserve its remaining behavior explicitly:
select the persistent client database alongside the workspace database and preserve the local Settings
effect on producer colors without giving the client workspace-storage authority.
The independent-client tests intentionally keep chrome preferences separate from
workspace-owned producer defaults. Public launch must resolve that distinction
instead of silently changing the local theme behavior.

The host finishes automatic recovery before admission. The first authoritative
inventory reconciles saved client targets, removing tabs for applications that
did not recover (including dead native terminals). Source/pack cold boots also
verify that recovered Settings retains its tab and live view. Subsequent inventories remove
previously observed applications when they exit. This is an admitted host's
complete inventory, not an inference from a timeout or a disconnected workspace.

Explicit opens from admitted clients now select matching retained checkpoints in
the host. Selection happens only after connection, workspace and operation-grant
checks; client-supplied recovery fields remain forbidden. The host skips live view
or instance IDs and checkpoints reserved by pending opens. A bounded correlation
record retains the chosen recovery fields through completion so an identical
retry reaches the broker with the same request fingerprint. The broker still
checks the application's current resume schema and supplies fresh execution and
mount capabilities. The client receives no checkpoint payload.
Reusing a client request ID with changed operation fields or arguments is rejected
before broker delivery, so that conflict cannot release the original open's
checkpoint reservation. Source/pack tests inject both a conflicting request and
an identical retry around the same open.
Source/pack acceptance opens manually recoverable Settings from Start after a cold
boot, verifies its saved pane and stable view/instance IDs, and replays the completed
open to prove it focuses the same application. Selection tests also cover live and
pending reservations. Direct supervisor requests keep their explicit restore
authority; this selection applies to the admitted-client open route.

The entry's private boot function constructs this local topology; the ordinary
externally spawned client entry must retain its trusted-context checks. Separate
these entry points without making an arbitrary payload bypass bootstrap authority.
Only the supervisor has host admission/shutdown authority. The client keeps its
own exact store grant and the session/presenter spawn scope.

Local quit must keep the entry execution alive until its supervisor has finished
host cleanup. The existing `exit_ready` protocol proves final client persistence,
but a terminal entry returning can stop the runtime and its child processes.
The private client supplies a save/finish handshake: save the client,
finish host cleanup while the client retains the physical display, then release
the client and observe exits. Cancellation leaves all owners running. A detached
remote client keeps the current save-and-detach behavior. Public command migration
is not yet complete; the private local-entry fixture
verifies the finish handshake through actual host cleanup. Startup, admission,
rendering and finish phases have ten-second failure deadlines; idle running has
no supervisor polling timer. A rejected renderer replacement pauses the client
for explicit retry. Presenter crashes likewise preserve the frame and apps;
the source/pack local-entry fixture crashes a presenter and verifies that F12
recovers the same live shell. The paused screen explicitly labels Ctrl+Q as
Emergency exit. That authenticated client request saves the layout and asks the
supervisor to finish host cleanup without a presenter-dependent confirmation.
Normal quit continues to negotiate. Both exit paths have physical-terminal
source/pack acceptance. A presenter that does not announce readiness within three
seconds also pauses; late readiness cannot silently resume it. A renderer transition
that exceeds ten seconds pauses without ending the host. The operation may still
complete: F12 explicitly reconciles with the host, while stale replies cannot
complete a newer request. Source/pack acceptance drops a renderer acknowledgement
after the host transition and verifies bounded pause, F12 recovery of the same PTY
and negotiated exit. These deadlines add no steady-state polling timer.

Use the runtime's `process.registry.register(name, nil, scope)` and direct
`process.send(name, topic, body)` addressing. The supervisor registers its own
execution; successful spawn alone is not endpoint readiness. A startup response
follows registration and initialization. Replies still authenticate the expected
execution PID, correlation ID and workspace identity. Re-resolve after restart
and establish a fresh attachment incarnation before accepting new control.

The local fixture exercises LOCAL registration and sends broker operations through
the name. Its catalog response gates the first named request. In the pinned runtime
the local registration capability is `process.registry.register` on the exact
name (not the `.local` spelling in the runtime spec). Wider scopes use their native
scope-specific policies. LOCAL names alone are not cluster-wide discovery; the
Hive profile must select an appropriate native scope and node-qualified identity.
No separate Bee naming registry or mesh transport is required.

Remote placement requests go to the destination supervisor or its workspace
service. That owner authenticates the requesting peer/execution, resolves its
admitted actor/resource mapping, establishes local security context and starts
the admitted application. Payload actor IDs, display names and thread membership
do not select privileged local identity. Existing actor messaging remains direct
native routing; new execution and presence registration remain owner operations.
The current fixture proves local named delivery only, not remote actor admission.

## Current coupling to remove

`src/core/workspace/main.lua` starts the physical terminal before opening storage,
spawns the session and broker, mounts the presenter, routes input and commits
application checkpoints. `src/core/session/main.lua` accepts windows only for
the single bootstrapped workspace. `src/core/applications/broker.lua` still selects
one desktop recipient. Its private `attachment.lua` module owns the recipient-and-grant
record held by each application instance and revokes before replacement.
Broker open/readiness work without
that recipient, and mount failures retain ready producers. The recovery envelope combines client layout with application
state. These are explicit local assumptions, not reusable multi-client contracts.

The private `bee.workspace:persistence` library now owns opening the configured
store, loading its stable identity, decoding the saved envelope and serializing
typed writes. It has no TTY dependency. The workspace actor still owns its lifetime
and decides when a checkpoint is committed. The recovery desktop type contains
only scene, tabs and preferences; the live application catalog is not saved state.
This extraction preserves the existing database format and migration ledger.

Owner requests can now bind one exact workspace/instance/view independently.
That operation leaves other view grants and the default recipient for future
opens intact. The whole-broker bind remains for local presenter replacement.
This is a per-view controller boundary; production observer admission and
independent desktop clients still require the steps below.
Owner-only `unbind` additionally revokes controller grants by exact recipient PID
and clears a matching default recipient. Its source/pack Terminal test uses a
second consumer actor to prove that detaching one recipient leaves the other's
command input and observations usable. Applications stay running, and revocation
errors preserve failed records rather than reporting a completed detach.

## Owners after extraction

| Owner | State and resources | Failure boundary |
|---|---|---|
| Local launcher | Starts the local host and client, supplies explicit resource bindings | Retains today's single-command startup and negotiated quit |
| Workspace host | Workspace ID, primary database, admission/broker, app recovery and appearance | Host failure makes its work unavailable; client loss does not stop it |
| Broker | App instances, producer viewports, readiness, close negotiation and authorized attachments | One failed attachment does not terminate an otherwise ready app |
| Desktop client | Physical terminal, client identity/store, workspace connections, session and presenter | Exit saves its layout and detaches; stopping hosted apps is explicit |
| Session | One client's composed scene, stable local tab IDs, focus, geometry and chrome preferences | Can rebuild from the client's saved layout and fresh host observations |
| Presenter | Input prediction and composition over client-owned attachments | F12 replaces it and reacquires recipient-bound mounts |

Keep the launcher policy explicit: local mode can continue to own and shut down
the host it created, while an attached client cannot infer permission to shut
down a pre-existing host. Detach and close/stop must have separate operation
outcomes before the first independently persistent host ships.

## Identity and appearance

A local tab ID is a client layout key. Its target is the full
`{workspace_id, instance_id, view_id}` reference. Never use an unqualified remote
view ID as the scene key; different workspaces may contain the same value.
Pending requests retain the target and the live attachment incarnation so a
late reply cannot affect a replacement tab. Workspace ID validation and actual
sender authentication both remain required.

The desktop integration must distinguish discovery from tab selection. A host
inventory snapshot can update selected tabs and offer other running views, but
must not automatically bind every discovered view. Rejoin reacquires only that
client's selected targets. Opening or explicitly selecting a view can request
its attachment; joining a second client alone must not displace an existing
controller. The private client implements selection isolation; normal launch still
uses the combined workspace owner.

Client preferences own wallpaper, desktop chrome and tab presentation. The
workspace/application owns producer page defaults and application appearance.
Two clients with different themes observe the same application pixels; neither
may recolor the shared producer merely by attaching. Normal combined-launcher
Settings changes both from one preference value. In the private client path,
the broker routes Settings through its current native attachment recipient to
the admitted client, which commits its preferences through its own session/store.
The response is client-scoped and does not change workspace producer defaults.
Unknown or replaced renderers cannot fall back to workspace preference writes.
Preserve the combined local experience until normal-launch migration makes the
scope explicit to the user.
The Classic terminal palette belongs to producer appearance, not client chrome.

### Presenter recipient ownership

The existing presenter calls `tty.attach` itself. Native mounts are bound to that
execution PID; forwarding a mount issued for the stable desktop client will not
make it usable by the presenter. A client initially renders through its own
execution. Its supervisor may select one different renderer using
`bee.host.client` with `op = "render"`, the admitted client `recipient`, and an
explicit `renderer` PID. An empty renderer clears presentation. Client `control`
permission is required; core owners, other clients and their selected or pending
renderers cannot be chosen. Client bind payloads still cannot select recipients.

`bee.host:clients` owns admissions, correlation and renderer
transitions inside the host actor. Replacement fences bind requests and old bind
replies, revokes the old recipient's grants, removes its monitor, then monitors
and selects the replacement. `bee.host.presentation` informs the stable client
with workspace/connection identity, renderer, `generation`, `pending` and error
fields. The supervisor receives a correlated `bee.host.client_result`. Selecting
the same ready renderer is an idempotent state notification.

Failed revocation retains the old renderer and bind fence for retry. A missing
replacement leaves presentation cleared. Renderer exit clears its grants while
retaining the client connection and apps. Client detach revokes its selected
renderer; detach queued during replacement cancels that replacement before
completing cleanup. Queues are bounded to one active transition and one deferred
detach per client. No new actor or polling timer is introduced.

The source/pack `clients` fixture uses actual native Terminals and separate
renderer actors. It verifies failed revocation/retry, stale generation denial,
reused public bind IDs, recipient-bound mounts, renderer exit, deferred detach
without timing sleeps, and unchanged Bash PIDs and variables across replacements.
The old renderer loses observation, input and resize; a second client remains
usable. The private desktop client uses this protocol for F12. The
existing local F12 path and supervisor-owned pending questions remain unchanged.

## Replaceable shell inbox

The client may own a separate inbox actor that receives authorized, typed UI
requests and exposes pending items to its shell. Keep it under the stable client
owner rather than the replaceable presenter, so swapping shells does not destroy
delivery state. Different shell implementations may render those items as modals,
notifications or an inbox through the same contract.

The originating workspace/app owns the request and decides whether a response is
still valid. The client inbox owns delivery, dismissal and presentation state;
the shell owns rendering and input. Correlate responses with the exact workspace,
instance, request and attachment incarnation. With several clients, the origin
accepts one valid answer and retires the pending request everywhere. Dismissal,
client disconnection and replacement are not consent. Preserve the current
broker-owned questions across F12 while extracting this delivery layer.

The private implementation uses `bee.client:inbox`, a pure module inside the
stable client actor. A separate inbox process remains optional. The broker still
owns pending requests; `bee.interaction:delivery` keeps only host-local selections
and dispatched-answer state. Source/pack desktop acceptance covers Terminal close
delivery and presenter replacement; this is not yet part of normal launch.

`bee.host.selection` carries workspace/connection identity, a monotonically
increasing selection revision and at most 16 exact view/instance pairs. The host
authenticates the sending client and requires its supervisor-selected `control`
permission. Selection expresses interest, not additional authority. Connection-
qualified `bee.host.questions` snapshots contain only matching questions; workspace
shutdown questions stay on the supervisor route.

`bee.host.answer` echoes the selection revision and exact question/view/instance
identity. The host dispatches at most one answer while that question remains
pending. `bee.host.question_result` acknowledges dispatch or reports rejection;
only broker publication establishes retirement. Failed delivery permits retry.
Detaching removes selection, and replacing a renderer preserves unanswered
questions. The client maps native view IDs to its tab IDs for presentation and
reverses that mapping for answers. Admitted-client close requests also require
the current instance ID, so a stale tab cannot close a replacement instance.

## Local attachment proof first

1. Implemented at the broker: an admitted app can reach ready and checkpoint
   before any view is attached. A mount error is an attachment result, not an app
   startup failure. The Lua fixture in `tests/fixtures/attachments` verifies
   persistence before attachment, survival past the startup deadline, failed
   initial and later mounts, and reattachment to the same producer. Startup
   timeout and observed EXIT handling remain intact.
   The fixture also keeps an old handle open across detach and proves that
   observation, input, resize and reattachment are denied after revocation.
   An injected revoke failure returns no replacement mount and preserves the
   previous grant for a later retry. The pinned foundation patch makes revocation
   idempotent after recipient cleanup, so an already removed grant is not a
   handoff failure. Binding several applications is still a per-app operation,
   not an atomic transfer of the entire desktop.
   Its Terminal mode opens the real bundled `bee.console:app` without a physical
   TTY, sends a shell command through its mount, detaches, and reconnects with a
   fresh mount. It verifies the same Bash PID and shell variable remain, the old
   grant cannot send input, and resize reaches `stty size`. Source and pack pass.
   This is one local broker and a reconnecting consumer, not multi-client or remote
   Bee attachment. Use this actual Terminal as the first remote application gate.
2. Introduce owner-held attachment records for exact view references and actual
   recipient PIDs. Separate observe from input/resize grants. Keep one controller
   for each PTY; observers do not resize it to fit their own windows.
   The isolated `observation` fixture proves the native prerequisite: separate
   controller and observer mounts receive updates from one producer, observer
   input/resize/redelegation are denied, and revocation closes the observer stream
   while the controller continues receiving frames and resizing. The observer
   runs in a separate actor and cannot attach the controller's unused grant;
   the intended controller subsequently attaches that same grant successfully.
   Status acknowledgements authenticate the observer's actual PID. This proves
   native recipient isolation, not independent desktop client owners or production
   observer admission. Bee's public broker operations still issue controller mounts only.
3. Extract a host entry point with no `tty.start`, physical surface, input listener,
   session or render timer. Start it with explicit host-selected database and
   policy bindings. Do not expose arbitrary database paths as caller authority.
4. Move physical-terminal lifetime and session/presenter supervision into the
   client. Local launch composes those actors over the same attachment contract
   later used by a remote client. Preserve F12, pending dialogs and prompt exit.
5. Allow two local client owners to maintain independent layouts against one host,
   then one client to compose two independently identified hosts. Only after those
   pass should a Hive profile resolve remote owners through native mesh naming.

These steps are one extraction milestone. Merely adding a `headless` branch to
the existing terminal loop does not establish the required owner separation.
Keep the current local launch usable throughout; do not publish the profile until
its lifecycle and recovery gates pass.

The pinned source CLI can execute this fixture on `--host bee:workers` with no
terminal host entry. Its pack launcher currently calls `launchExecProcess` with
an empty host ID (`cmd/wippy/cmd/run_pack.go`), ignoring the explicit selection;
it still needs a passive terminal host entry even with piped input/output and no
physical TTY. Preserve host selection in pack execution before claiming a
source/pack no-terminal-host profile. The source and pack fixture checks expose
this distinction rather than treating their boot paths as equivalent.

## Protocol and authorization

Use native actor messages, registered contracts and typed consumer libraries.
The client sends bounded requests; the host authorizes and returns correlated
results. Catalog metadata describes operations but does not authorize attachment,
spawn, stop, resize or publication. Discovery is not enrollment.

The pinned W1 contract probe shows that a bound function has its own execution
PID. Do not forward a claimed original PID and treat it as authenticated. A
contract adapter must use verified runtime security context or an owner-issued
capability scoped to the requested resource and operation. Actual message sender
checks still protect the private actor boundary. W2 behavior needs its own proof.

Remote input must run outside the presenter's event loop through bounded queues.
Do not retry uncertain keystroke delivery. Observe streams may coalesce snapshots;
control operations need explicit success, denial, disconnection or unknown outcome.
Do not put a new network transport underneath Bee when native mesh provides it.

## Storage migration

The private [client state store](CLIENT_STATE.md) now supplies qualified layout
values, a separate client identity/database, generation checks and atomic legacy
import receipts. Source/pack fixtures verify retry after restart without replacing
later client edits. The private desktop actor uses the store; automatic legacy
import and host acknowledgement are not wired yet.

The host retains workspace identity and app checkpoints. The client has an owned
store for its identity, qualified tab references and layout. Fresh clients do not
write the workspace's old desktop envelope. Neither store contains live mounts,
execution PIDs, credentials or authorization tokens.

For an existing local database, import its desktop once as the first local client
layout. Retain its application records and workspace ID. Give the import a stable
receipt so interruption between writing the client store and recording completion
in the host store is retryable. This is not a cross-database transaction: write and
verify the client import before acknowledging completion at the host. Never remove
the recoverable source layout before a durable destination exists. Applied
migrations remain immutable; schema version checks prevent an older binary from
silently rewriting the new state.

## Required acceptance

- Launch an admitted app without a TTY or client, receive readiness and a committed
  checkpoint, then attach and observe its first complete frame.
- Disconnect a client during a run and during a pending confirmation. The host
  retains work; an unanswered question does not become acceptance. Reattach with
  fresh recipient-bound grants and recover the question and frame.
- Exercise two clients with different layout and chrome preferences. Only the
  controller can resize/input; stale controller grants fail after a handoff.
- Compose two workspaces with colliding instance/view IDs and equal display names.
  Open, close, focus, dialog responses and late replies affect only their targets.
- Prove source/pack local boot, default no-network behavior, F12, native shell
  execution, responsive quit and negative permissions still work.
- Interrupt each legacy-layout import step; restart without duplicated imports,
  lost application state or newly minted workspace identity.
- Boot two actual Bee runtimes before claiming Hive: authorize attachment, transfer
  control, lose/reconnect transport and lose a host. Never silently relaunch a
  disconnected remote app locally. Measure idle work and bounded queue behavior.

Infrastructure services, synchronized components and CI harnesses can consume
these owners later. They are not reasons to move their domain logic into the
desktop or to delay proving this extraction.
