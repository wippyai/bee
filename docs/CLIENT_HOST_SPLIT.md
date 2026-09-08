# Workspace host and desktop client extraction

Status: extraction in progress; a private TTY-free host actor is implemented and
tested separately from the current local desktop.
The required behavior and native mesh boundary are in
[workspace attachments](WORKSPACE_ATTACHMENTS.md). Local Bee still combines the
physical terminal owner and workspace host. No headless profile exists yet.
The current wide-terminal header shows the workspace's short durable ID; it is
informational, not a workspace switcher. The generic idle "Ready" label is gone.
The runtime registry stores definitions/history separately from the workspace
application store and journal; none of those storage paths is a UI workspace name.

`bee.workspace:host` owns its broker, configured persistence, automatic app
restoration and checkpoint receipts. Its bootstrap is restricted by host context
and exact core-spawn policy. Its supervisor selects admitted client executions
and their open, close and control permissions; ordinary applications cannot spawn
the host or admit clients. The `host`
fixture opens and checkpoints without a physical TTY, detaches a view, stops the
host and proves stable workspace/view/instance identities on automatic restart.
The fixture selects the host's process and storage policies explicitly.
It also sends a correctly addressed open from a different actor and verifies
that the unauthorized application never appears in the restored membership.

This private entry is not yet used by `bee` and has no public command or headless
profile. It admits client actors but does not yet integrate desktop clients,
deliver their catalogs or questions, or persist their layouts.
Its supervisor is a stable owner, not a replaceable presenter; losing that
supervisor ends the host. Local launch still uses the existing combined owner.
Do not run both owners against the same database: generation checks reject stale
writes, but they are not host election or a multi-writer protocol.

### Private client admission

Only the bootstrapped supervisor may send `bee.host.client` with version 1,
request ID, workspace ID, exact recipient PID and `admit` or `detach`. Admission
requires explicit `open`, `close` and `control` booleans. The host monitors that
execution and supplies a fresh connection ID through `bee.host.admitted`.
Requests must match both the actual sender and the connection ID; metadata does
not grant access. Changing permissions requires completed detach first.

Client requests use `bee.app.request`. The host isolates request IDs by connection,
forces targeted bind recipients to the admitted execution and denies host recovery,
whole-workspace binding, unbind and shutdown. There are at most eight admissions
and 128 retained request routes; exhausted pending capacity returns `busy`.
Completed routes are evictable, so this is bounded correlation, not durable
exactly-once execution. Open replies omit resume state and mounts; targeted bind
returns the recipient-bound mount in `attached`.

Detach disables further requests before revoking grants. A successful
`bee.host.client_result` follows revocation and monitor removal. Failure retains
the disabled admission for retry. Execution exit initiates the same cleanup;
application processes remain alive. The `clients` fixture proves two actor
clients with equal public request IDs, stale-grant denial, permission replacement
rules, fresh connection IDs, automatic exit cleanup and retained native shell
state in source and pack. These actors are not independent desktop sessions yet.

## Named supervisor endpoint

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
This is a per-view controller boundary; observers, client admission and independent
client layouts still require the steps below.
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

Client preferences own wallpaper, desktop chrome and tab presentation. The
workspace/application owns producer page defaults and application appearance.
Two clients with different themes observe the same application pixels; neither
may recolor the shared producer merely by attaching. The current local Settings
operation changes both from one preference value. Preserve that local experience
during migration, then make the scope explicit when multiple clients are enabled.
The Classic terminal palette belongs to producer appearance, not client chrome.

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

This inbox is a proposed client process boundary, not a new globally trusted
mailbox. Its limits, sender admission, allowed response shapes and replay rules
must be checked independently of the visual shell implementation.

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
