# Foundation status

The September 12 Agent integration branch has a verified standalone component
candidate, source `cf667d8`: retained provider homes exclude concurrent attempts,
interactive continuation resolves committed hook observations, and application
resume state becomes visible only after persistence acknowledgement. Existing
provider fixtures and native executable checks pass. Public Agent conversation
recovery still needs saved-state and fresh-admission wiring; the default picker
has no production launch profiles. Global installation remains gated on
per-project default state selection in the runtime. See
[the current integration checkpoint](handoffs/AGENT_INTEGRATION.md).

Native Agent windows now attach their placement attempt before opening the PTY
and receive a host-selected cooperative close allowance. The actual child/HTTP
hook test passes with a three-second claim delay: input remains responsive,
duplicate submissions produce one observation, and the cancellation receipt is
durable before the broker reports close. All 616 Lua tests, three managed-window
tests and the remaining foundation checks pass across the initial run and
targeted continuations. Two fixture-path omissions were fixed so governance
uses disposable databases in workspace-host and source-free acceptance.
The initial cached lint failure was preserved; fresh strict lint passes unchanged
source with the existing desktop-lifecycle warning. Global Bee is unchanged.

The September 11 Agent integration now includes governed authoring and claimed
hook recovery. All 600 Lua tests pass; actual restart checks preserve frozen
authoring content, retry receipts and the migration ledger. Exact operation and
workspace grants are checked even for the stored author. Revoked hook recovery
proves a committed record is reconciled once after a lost acknowledgement.
Source/pack headless checks pass. The earlier intermittent missing fault
diagnostic remains unexplained; this is not an uninterrupted full-check pass.
Public MCP activation and native Agent conversation recovery remain open.
Architecture tests and their build gate were removed at the user's direction;
behavioral permission and recovery tests remain. Global Bee is unchanged. See the
[current Agent checkpoint](handoffs/AGENT_INTEGRATION.md).

The Agent window now has a profile-selection phase and `agent` command metadata.
It lists bounded host-defined window profiles, carries the displayed plan into
admission, and requires refresh after a changed plan. Real broker acceptance
passes empty-list recovery, changed-plan refusal before work, mouse launch and
native terminal continuity. The selector closes its drawing surface before PTY
attachment and reuses the input subscription. All 578 unit tests pass; the
current narrow-window follow-up also passes its six focused selection tests.
Native packaging covers 14 modules / 589 entries. The source-free executable
`bee agent` path passes empty-catalog, F12, close-without-work and 0.120-second
detach acceptance. Broader checks remain pending; this source is not installed
globally. A selectable profile now requires its host policy to contain an
absolute executable binding. Exact policy binding waits for the driver to
prepare its executable on the launch path. Provider configuration remains
driver-owned and is checked after a user selects the plan but before Bee creates launch work;
for example, a Codex policy without its provider refuses without creating a
thread. A named provider entry is measured into the selected plan, so changing
its model or endpoint requires refresh and refuses a stale selection. Listing
never executes a driver function. The host-owned
[source fragment](../examples/agent-profiles/README.md) supplies the current
build-time composition path for Claude Code and Codex window definitions.
Installation and overlay activation remain unimplemented. Authenticated turns,
production process-tree cleanup and scoped MCP remain open acceptance gates.

Selected launch plans can now be carried into admission with
`expected_plan_digest`. A changed plan refuses before thread/resource/credential
effects; a matching plan follows normal admission. All 572 unit tests pass,
including changed-policy refusal and malformed-digest validation, and actual
broker-spawned window acceptance passes with the digest in its launch envelope.
The profile selector and public CLI wiring remain unimplemented. Broader
validation remains pending; this source is not installed globally.

Native placement now rejects conflicting environment ownership: `HOME` belongs
to placement, gateway token destinations belong to the gateway, and credential
projections cannot overwrite either those destinations or policy values. The
focused native suite passes all 20 tests, including refusal before intent and
credential-collision refusal before child start without secret bytes in evidence.
Disabling the credential overwrite guard in a disposable fixture makes exactly
that regression fail (19 pass, 1 fail).
All 570 combined unit tests pass for environment ownership and named-profile
isolation. The broader gate remains pending; global Bee is unchanged.

The profile work first corrects launch admission to read its definition, driver
catalog and policy from one registry snapshot. Managed admission also refuses caller environment before creating a thread;
the selected policy and credential broker supply it. All 567 unit tests pass,
including a real registry-update regression; restoring a live policy read makes that
regression fail. Managed-window and source/pack harness isolation checks pass.
The preceding driver checkpoint's complete foundation gate is recorded below;
this admission follow-up has not repeated that broader gate or changed global Bee.

The current driver source adds a shared `configure` contract method and generic
`provider_ref` launch policies (`bee.launch-policy@2`). Carrier and placement
resolve activated bindings from pinned snapshots; placement rerenders and checks
the private-home file before creating intent. A third-driver fixture proves
materialization without provider-specific imports in either caller. The native
harness receives scope-management authority only through protected host admission;
ordinary apps keep their existing denial. All 565 unit tests pass on the runtime
candidate. The remaining `make check` recipes also pass (the already-passing
unit prerequisite was omitted), as does standalone executable acceptance. This
source is not in the global executable. Gateway content combined with provider configuration
remains Codex-specific, and authenticated turns and production process-tree
cleanup remain separate acceptance gates.

Global Bee now includes local Hive Manager display browsing through exact
supervisor-selected reader admission. Native catalog/connection checks pass on
the final binary; source real-actor checks prove revocation and native-control
denial. Remote browsing and switching remain unfinished. The installed SHA starts
`5c604fa7`; existing running nodes retain their loaded code until restarted. See
[the build handoff](handoffs/GLOBAL_BUILD.md).

Current global Bee includes app transfer between independent displays, friendly
names, retained-display recovery and observer-safe assignment projection (SHA
`2569142f`, source `4e57054`). Public two-client transfer preserves the same shell
PID/state; final unit, executable, client/launcher/recovery and source/pack gates
pass as documented in [the build handoff](handoffs/GLOBAL_BUILD.md). Actual-user
cold/warm frames were 1.433s/0.209s, with about 0.11s detach. Live Hive Manager
browsing/attachment and workspace switching remain unfinished. Older checkpoints
below describe earlier installations and narrower evidence.

The September 11 global build now includes the production Hive eventual-name
cleanup permission fix (`6c6c574`, global SHA `82afdae8`). A controlled native
regression proves name release and fresh-PID publication on service re-add;
removing the permission reproduces the failure. Actual-user cold/warm frames
were 1.976s/0.218s, with clean 0.114s detaches. The initial retained desktop exit
remains unexplained. See [current build](handoffs/GLOBAL_BUILD.md).

Hive Manager source now retires departed node/display-client rows after 60 seconds
of absence in complete native membership samples. Returning nodes cancel retirement;
a failed or truncated membership sample resets the grace period while still
updating the members it reports. Repeated partial samples keep the presentation
cache bounded at 64 rows, preferring local and selected nodes under pressure.
Returning nodes clear departure status. Removing a node also clears pending and
saved-selection hints so another node cannot inherit its desktop selection. Retirement only
removes the manager's cached row, catalog and session presentation; saved display
layouts and application processes are untouched. Refresh is every five seconds
when its directory worker is idle, so cleanup may occur later than 60 seconds.
This change is installed globally as application source `6b2da06`; 516 Lua tests
and native client/binary checks pass. The intermittent startup/expired-mount
failure remains unresolved. See [current global build](handoffs/GLOBAL_BUILD.md).

The earlier global executable included native `a0fc01e088b2`, the proven physical
cancellation-order fix, with unchanged Bee source `c3b2c9f` and runtime `674b58a1`.
Native-client/standalone acceptance and focused race/vet pass; actual-user observe
reached a frame in 217 ms and detached in 87 ms. Global SHA starts `2c1f1109`.
Intermittent startup and detach failures remain unresolved; this is not sustained
reconnect acceptance. See [current build](handoffs/GLOBAL_BUILD.md). Older dated
checkpoints below describe previous installations and their evidence.

The source now includes an owner-local sync ledger, editable node descriptions
with a metadata trait, and multi-source approval inbox feeds over the existing
Hive policy route. Node updates use revision CAS and caller-scoped retry receipts;
all schema changes use the checked migration lifecycle. Two-runtime acceptance
passes metadata read/update/replay, mapped read-only denial/revocation, and
approval snapshot/decision/catch-up with revoked visibility. The local inbox
application smoke and 508 Lua tests pass. The full repository check passes,
including source-free packaging after adding the node database to the fixture's
isolated environment. The two-runtime feed gate also passes with the race-enabled
harness. This is source evidence, not a global binary installation or Hub publication.
See [sync and inbox](SYNC_AND_INBOX.md) for authority, retention and enrollment
limits. Governance source now provides a host-admitted, caller-owned staging
workspace with revision checks, retry receipts and frozen file snapshots. It has
no default authoring grants and cannot activate an overlay, install from Hub, or
replicate through Hive; those remain separate acceptance gates.

The currently installed September 10 candidate (production c3b2c9f, native
ced4008999f4, runtime674b58a1) passed full `make check`: 494 Lua tests,
525 source/pack entries, storage/restart, permissions, desktop/client lifetimes,
recovery and bundled apps. Evidence: `/tmp/bee-hive-session-identity-full-check.log`,
session61042, exit0. The existing desktop_lifecycle convergence warning remains.
Native-client and standalone gates74144/79123 also passed. The global executable
SHA starts `cbb6d6a5`; [the build handoff](handoffs/GLOBAL_BUILD.md) records full pins.

`bee desktops`, `bee attach WORKSPACE DISPLAY` and `bee observe WORKSPACE DISPLAY`
now select existing local desktop identities through authenticated supervisor
admission. Occupied/foreign selections refuse without allocation. Hive Manager
session presentation is qualified by node and owner generation. Actual-user
cold/warm/observe frames took1.486s/0.215s/0.221s; detach took0.077–0.086s.
The user databases were preserved. One-hour diagnostic50459 remains pending on
the previous build. Live workspace switching, multi-host composition and public
remote recovery remain unfinished. Earlier dated measurements below describe
previous candidates, not newer acceptance.

The latest September 10 global candidate now selects an independent desktop when
another physical client controls the default. It reuses an available durable
identity before allocating another; explicit selection and observe do not fall
back. The public native suite proves three simultaneous desktops, F12, reuse,
clipboard, bounded detach, retained shells and client-crash reconnect. Quit-dialog
presenter replacement also passes source/pack acceptance. Cold-node connection
stages allow 60 seconds, with immediate successful progress and cancellation.
The actual user state booted in 1.572 seconds after the authorized restart.
The independent-desktop source passed the combined full repository check
(490 Lua tests, 524 registry entries). This is not full-release acceptance. The older retained node's idle connection hang remains unexplained.


The global candidate installed September 10 now uses the native owner/client
launcher. Ordinary `bee` loads embedded code with shared registry history and
attaches through the same-machine native mesh. Ctrl+Q and Ctrl+] detach the
physical client while retaining its owner and applications. `bee observe` adds a
read-only physical view of the same running desktop; it cannot send app input or
resize it, and refuses promptly if no Bee is running. Public executable tests
prove shared content and controller continuity after observer detach. Standalone startup,
selection/copy, scrolling, explicit-detach reconnect and old-binary upgrade checks
pass. Warm launch now reuses the existing runtime lock and skips an extra owner
process; one standalone probe reached the retained desktop in 0.204 seconds.
Abrupt client death now has a standalone regression: after a 40-second native
node-departure observation interval, a fresh client rejoins the same retained
shell. Bee's supervisors handle existing LINK_DOWN events and revoke the
attachment without terminating the owner or declaring remote process completion.
The isolated owner-service trace has no failures and passes race/vet. Immediate
exact-actor EXIT while transport remains live is still a failing runtime gate.
The source used by the installed observer build passed one uninterrupted `make check`, including
486 Lua tests, source/pack architecture at 517 entries, storage and subscription
restart checks, all desktop/client/launcher/recovery gates and the bundled apps.
The 16-window load check exited in 323 ms. Both previously intermittent startup
failure points passed without increasing time limits; their causes remain
unexplained, so this run is not a claim that those intermittent failures are fixed.
Evidence: `/tmp/bee-membership-foundation-check.log` (session69756, exit0).
The observer build uses the same 365 production source files; its native launcher
and standalone suites pass separately on native142e753.
Named commands such as `bee terminal` now launch through controller admission to
the retained owner. Cold/warm command launches, literal arguments, replay, denied
observer launches and fullscreen provider aliases pass; the global binary is
installed and its isolated cold/warm smoke test passes. Existing owners keep
their previously loaded code until restarted.
See the current [runtime/build handoff](handoffs/STATUS_RUNTIME_GATE.md).
Older gate descriptions below refer to earlier candidates.


Bee is a local terminal desktop with on-demand default applications: Terminal,
Settings, Process Manager, Approvals, Timeline and Hive Manager. A fresh workspace opens no applications;
later boots restore applications that opted into automatic recovery. The source
and portable pack load only `src/`; fixtures and the legacy archive are excluded.
This file and [application contracts](APPLICATION_CONTRACTS.md) describe the
implemented boundary. Older design documents are proposals where they differ.

Settings provides 16 themes, 11 backgrounds and a Labels/Icons taskbar choice.
These preferences persist with the workspace. Compact tabs retain admitted app
icons, minimize/restore actions and the normal focus/overflow behavior.
Windows Classic keeps its silver application panels and uses a black console
with light default text for Terminal. Start and context menus align shortcuts
and submenu indicators; the BEE arrow reflects only the Start menu state.
Title/tab context menus also support user labels and named accents. The session
owns these values independently of application identity; supported recovery
restores them. Apps can announce their own bounded titles through the authenticated
broker; user labels retain precedence. Native PTY title forwarding is not implemented.

Applications can request bounded confirmation and single-line text dialogs.
The broker owns pending requests; the shell presents them and isolates input.
Questions survive F12, while app exit clears them. Apps may opt into negotiated
close at readiness; confirmation/cancellation and an unresponsive-app force-stop
choice are implemented. Normal workspace quit gathers guarded-app decisions before cleanup. The bundled
Terminal opts in and conservatively confirms every PTY close. Emergency exit from
failed-presenter recovery bypasses negotiation.

The installed candidate adds **Select text** to window context menus. Right-click
the body, title or tab; Shift-right-click in the body goes to the application.
Selection freezes one body; left-drag selects text and Ctrl+C requests clipboard
output from the physical client. Source/pack and standalone checks prove exact
foreground text with overlapping Terminals. Selection is absent from persisted
state and viewport snapshots. The native owner/client route sends a session-qualified
Copy request through the existing supervisor protocol; F12 and reconnect do not
replay it. Native text extraction and clipboard capabilities come from the candidate
runtime, not a released runtime main pin. Public remote selection remains open.
See [selection and its acceptance limits](handoffs/TEXT_SELECTION.md).


## Ownership

Public local launch uses the host/client split and the installed candidate's
embedded-default policy. It preserves shared registry history and application
state. `bee --base` is an explicit recovery path; it is not required for ordinary
launches to use embedded code. An already-running owner keeps its loaded code
until restarted. The runtime changes remain on the candidate pin; see
[the runtime cutover handoff](handoffs/RUNTIME_UPSTREAM_CUTOVER.md).

| Owner | Responsibility | Replacement boundary |
|---|---|---|
| Local supervisor | Host bootstrap, client admission and coordinated local quit | Local launch restart |
| Workspace host | Workspace persistence, recovery, client permissions and authoritative inventory | Host restart |
| Desktop client | Physical terminal, client layout persistence and presenter recovery | Client restart |
| Session | Complete committed desktop projection: scene, stable tabs, preferences | Client restart |
| Broker | Protected app admission, instance/process identities, producer viewports, app lifecycle | Host restart |
| Presenter | Input prediction, drag previews, menus, composition and delegated attachments | Live F12 rejoin |
| Application | Its own content and child resources | Close/stop then fresh instance |

The client caches the session projection; it does not independently edit tabs
or preferences. Rendering consumes values. App metadata supplies launcher groups
and presentation roles; core code contains no bundled-app IDs. Shared UI helpers
are optional; the Terminal uses Wippy's native PTY proxy directly.

Applications receive identities before spawn and acknowledge readiness. A spawn
alone is not an opened application. Readiness has a three-second deadline and
does not require a presenter attachment. The broker can retain a ready producer
and accept its checkpoints while detached; a mount failure reports attachment
failure without killing the app. Source/pack Lua acceptance checks this through
piped execution. A low-level `bee-host` command now owns the existing workspace
host without a desktop. It must execute on `bee:workers`, not the runtime's
default terminal command host. Source/pack acceptance covers piped readiness, stable
workspace identity across restart and bounded SIGTERM shutdown. Managed headless
launch, supervisor discovery and public remote enrollment remain unimplemented.
`make workspace-hosts-check` proves two host actors in one runtime with exact
separate database grants, concurrent sender-qualified requests, cross-workspace
target rejection, Settings checkpoint recovery and independent workspace IDs.
It passes from source and a source-free pack. Public launch still selects one
workspace; dynamic workspace activation, scoped catalogs and dormant-workspace
resource costs remain unproved.

Unguarded close
sends the producer a cooperative close event, then requests termination after
250ms. Guarded apps enter this cleanup only after an accepted decision. Records remain owned until EXIT; unsuccessful termination reports
uncertainty rather than claiming the process stopped. Workspace exit starts all
child cleanup together and does not serially wait for each close deadline.
The store remains available during cooperative cleanup; global shutdown preserves
recovery records. Completion waits for observed exits and known writes, with a
bounded error path for incomplete cleanup. Applications requiring a durable save
before accepting close must wait for their checkpoint receipt.

F12 retires only the presenter. The broker revokes old mounts and binds new ones
to the fresh PID. App processes, PTYs, viewport content, geometry, tab order and
preferences survive. Retry exhaustion preserves the last physical frame and
allows F12 retry or Ctrl+Q exit. Failure of the session or broker ends the workspace.
Rejected structural workspace-to-broker/session sends end the local workspace
with a visible error through its save path. Bind, restore, accepted shutdown and
checkpoint-receipt failure tests verify recovery survives and healthy reboot
works. Rejected ordinary open/close and quit preparation preserve running apps,
report failure and permit explicit retry.
Presenter snapshots remain reconstructible; this is not remote reconnection.
Workspace preferences and opt-in app checkpoints survive cold starts in the primary
workspace database. Settings demonstrates the resume contract. Terminal does not
claim to resurrect native processes after runtime shutdown.

Host-admitted clients without control permission can observe an existing
application through separate recipient-bound mounts. Source/pack desktop checks
cover different display sizes, F12 and observer loss while the original controller
continues using the same Terminal. Observer frames are clipped locally; input and
producer resize are denied. Public shared-desktop selection and explicit controller
transfer remain unimplemented.

## Security

Ordinary apps receive `process.send` and their producer capability, plus only
policies named in protected admission bindings. Metadata cannot select grants.
App scopes explicitly deny scope/context escalation and direct registry/overlay
mutation. Private core process spawning is denied to apps and the broker. Core
bootstrap checks the context installed by the workspace, not just a caller-supplied
owner argument. Receivers authenticate actual sender PIDs before interpreting data.

Settings receives an appearance-write operation grant. Process Manager receives
read-only runtime metrics plus a broker stop operation grant; core and supervisor
service control remain protected. Terminal alone receives its named native executor
and native command execution. Empty arguments launch `/bin/bash -i`; registered
CLI handlers launch `claude`, `codex` or `agy` fullscreen with literal arguments.
These programs must be installed on PATH; agent integration is not implemented.
Bash supplies interactive line editing
and history navigation. It has no ambient foreign TTY authority.
Producer capabilities and recipient-bound mounts carry terminal rights.

**Native shells run with the local OS user's authority.** They can access that
user's files and network, including editable Bee source. Runtime policies isolate
Lua actors; they do not sandbox native code or protect against the OS account
owning the files. No untrusted-code sandbox is claimed. An overlay-owning service
will be the sole runtime publication authority when implemented; direct registry
mutation is denied to applications today.

## Reproducible runtime and validation

`make setup` uses the Go builder and `wippy.build.json`, the same runtime and native
components used for standalone releases. The builder disables ambient Go workspaces
and verifies its pinned checkout. Bee's own source is MIT; the remaining runtime
patches retain MPL-2.0. Removing those patches requires the upstream changes tracked
in [runtime upstream work](RUNTIME_UPSTREAM.md).
The published build has completed that migration. This shared checkout retains
parallel host/Hive experiments; see [the runtime cutover handoff](handoffs/RUNTIME_UPSTREAM_CUTOVER.md)
before publishing those changes.
The local host work also preserves explicit command-host selection for packs,
needed to execute the headless entry on a worker host; its upstream acceptance
remains part of that workstream.

The workspace alone opens `bee:workspace_db`, a separate SQLite store from runtime
registry history. Its append-only migration ledger verifies names and checksums;
newer or altered migrations fail closed. Generation checks reject stale writers.
Migration 2 assigns a stable opaque workspace identity without changing the
existing envelope or migration 1. The ID survives reopen and database relocation.
The workspace supplies this ID through trusted broker bootstrap and application
launch values. The app SDK exposes a copied logical view reference. Broker
replies and desktop windows retain the workspace ID; workspace/presenter replies
for a different workspace are rejected. Local application requests carry an
explicit target checked by both the workspace and broker. Missing or foreign
targets return an error without executing locally. Mixed-workspace composition and public
remote launch are not implemented; the internal remote attachment fixture is described below.
Apps checkpoint through their broker; a successful receipt follows database commit.
See [storage](STORAGE.md) and [application contracts](APPLICATION_CONTRACTS.md).

`make check` runs typed lint, pure model/protocol/lifecycle tests, import and loaded
registry audits, and real source/pack terminal acceptance. Native terminal tests
exercise execution, PTY isolation, input, resize, interruption, rejoin, color fill,
close and registry/TTY access denial. Acceptance uses disposable stores and never
modifies a user's workspace history. CI runs the same setup and checks.

## Next boundaries

[Hive startup](HIVE_BOOTSTRAP.md) is in progress. The native manifest includes a
runtime patch for retained automatic listeners, concurrent authenticated startup
and graceful rejoin at a new port. It also includes an actor-ingress patch that
rejects source-node claims inconsistent with the authenticated peer; its full
internode race suite and clean native toolchain build pass. See
[Hive boundary proof](HIVE_POC.md) for the external-peer forwarding limit.
CLI acceptance passes for twenty isolated
runtime processes, including three Raft servers with converged leadership;
the fixture explicitly aligns relay and gossip node identities. Bee pairing,
project-host discovery, managed headless
launch and public remote enrollment remain unimplemented. Runtime transport tests
are not Bee cluster acceptance.

An experimental two-runtime source fixture now proves supervisor-selected Bee
host admission, destination Terminal execution, resize, revoked input and fresh
mount reattachment to the same live shell. It passes both locally and across two
machines through native mesh transport. `make hive-remote-check` also checks
coroutine progress while a destination viewport resize is stalled;
`make hive-lan-check` requires explicit remote test coordinates. Both use the
current native manifest toolchain; see [the exact scope](HIVE_POC.md).
Public enrollment, discovery and a remote desktop selector remain unimplemented.
The internal Hive supervisor implements bounded challenge exchange, peer
replacement and asynchronous open telemetry dispatch. A two-runtime fixture
proves discovery by native node-qualified names, calls in both directions,
sibling rejection and supervisor restart. It uses explicit fixture enrollment
and boot scopes. The current standalone launcher now starts the same-account
owner supervisor automatically; public external enrollment is still separate.
Hive Manager refreshes supervisor lookup, membership and owner telemetry. The
installed app now draws local Hive state before querying peers and performs
directory calls in one asynchronous worker, keeping input and close responsive during slow queries.
Concurrent refresh requests are refused visibly instead of accumulating work;
results remain keyed to their node. The installed standalone and source/pack
slow-query checks pass. A failed lookup is shown as **Hive supervisor unavailable** with its reason; it does not
infer that Hive is disabled or that enrollment would repair the failure. A found
supervisor is reported separately from each peer's reachability and desktop
availability. Detailed startup phases require an authoritative lifecycle source.
The installed revision separates the MEMBERSHIP and BEE SERVICE columns:
presence in the native member list does not imply a configured supervisor route.
Raft role is shown only under Details. This presentation change grants no access and does not establish peer connectivity.
Its standalone and full source/pack checks pass.
See [the supervisor boundary](HIVE_SUPERVISOR.md) for remaining activation gates.
`make hive-presenter-check` additionally drives the real presenter while the
destination runtime is stopped for fault injection. Start opens and F12 retires
cleanly within one second; input queue overflow is visible, and fresh attachment
retains the same Bash PID and variable. This is not public desktop discovery or
automatic recovery after network loss.

`make hive-desktop-check` proves the actual desktop client and session against a
workspace host in another runtime: destination Terminal execution and resizing,
F12, and a fresh client reconnecting to the same retained shell through its local
client store. This uses fixture-selected admission and pre-pinned test keys, not
the public launch/discovery path. It waits for the new presenter and retained
content in the same frame before typing; lossless input during reattachment
remains unproved.

The candidate `hive-desktop-admission-check` also admits a separate compiled
native client through the supervisor to a retained desktop. Its PTY mode proves
shell input, F12 with the same shell, resize, bounded Ctrl+] detach and restoration
of terminal settings. This requires the candidate runtime's isolation of blocking
stdin reads from terminal control commands. Explicit detach passes; remote actor
crash cleanup remains a failing native monitor gate, reconfirmed against the
current combined runtime on September 10. Ordinary second-`bee` auto-attachment
is now implemented and verified for explicit detach/reconnect. The physical LAN desktop fixture has passed
against `100.70.10.28`, including an owner-only file assertion and a separate
physical-process SIGKILL/rejoin to the retained shell with a fresh explicitly
enrolled client identity and automatic ports; same-name immediate rejoin remains
a separate failing runtime case; this does not establish the public remote launch route.

The local native thread journal is implemented and the rich thread authority,
delivery and projection are built on it; the Timeline application reads a
thread through the owner's subscription contract, with resume under a new
lease proven against the real owner. The isolated Lua subscriber fixture
remains separate.
Production views currently poll. Owner-local durable subscriptions preserve
acknowledged cursors across close/restart, fence old leases on resume, and reclaim
capacity only through explicit forget; the restart acceptance now passes on the
typed-listener candidate. Crash-safe job scheduling and dynamic membership remain
future work. See [threads](THREADS.md) for the
implemented API and limits, and [workspace attachments](WORKSPACE_ATTACHMENTS.md)
for the proposed identity split.

The shell remains the delivery focus. Hub installation, authorized overlay editing,
MCP, AI drivers and service/run
lifetimes are separate subsystems, not unfinished responsibilities of the presenter.

The first resource subsystem should own a workspace's named filesystem roots:
a stable resource ID, provider, authorized root, display name, and entry points.
Terminals, file views, Docker mounts and watchers reference those IDs instead of
embedding host paths into desktop state. Discovery may propose projects; it must
not authorize a root automatically. Native paths, container roots and virtual
providers need explicit resolution and containment checks at the provider boundary.
The terminal currently starts in the runtime's working directory; a resource binding
will replace that implicit choice once this subsystem exists.

## Native assembly

A pinned builder assembles Bee, Wippy and the typed native `ioevents` module for
Linux and macOS on amd64 and arm64. Standalone acceptance verifies source-free boot, Settings
recovery, native shell execution and F12. Base/bootstrap deployment handling and a
draft-release and Hub publication pipelines are implemented. A completed Hub upload
and update proof, in-app installation and stable distribution remain pending.
See [native distribution](NATIVE_DISTRIBUTION.md)
for the canonical update boundary and outstanding acceptance/license limits.

## Experimental computer owner

The [native computer owner](../native/computer/README.md) now has isolated
Windows VM acceptance for runtime-frame permission checks, one controller per
seat, child restart/crash/cancellation, stale grant/frame rejection and sustained
secure-desktop retirement. Parent and child use the same test executable.
It is not registered in the normal Bee launcher or exposed through Lua/Hive.
Actual login/logout recovery, execution-epoch wiring and lossless OS lifecycle
notifications remain acceptance gates. Linux uses a transport fixture in this
package; X11/macOS implementations are not integrated. Native race tests, vet
and Windows build/VM checks pass. The full foundation check was attempted and
stopped at 23 existing Lua lint errors; no passing full-suite claim is made.

The installed revision includes a private durable desktop catalog in the client
store: one default identity and up to 32 allocated identities, with no layout
content or live-availability claims. Source/pack storage and upgrade checks pass;
this helper is not exposed as public desktop selection yet.

The subsequent catalog source full run stopped on a presenter bug: a committed
window removal could leave its expired-view error in the header. The source fix
retires the removed attachment and clears only that window's error. A regression
fails on the old presenter and passes on fixed source/pack; the original Process
Manager scenario also passes. This does not fix or explain the separate retained
node's intermittent mesh disconnection. The protected desktop storage methods and
this presenter fix passed their combined full gate (486 tests, 519 entries) and
are installed globally. The actual-user smoke reached the desktop in 1.568s
cold, 0.222s on warm reconnect, and 0.219s through `bee observe`; all three
detached in under 100 ms. See the global build handoff for exact evidence.

The subsequent source Hive desktop route now publishes the durable catalog with
an explicit default, supports idempotent identity allocation, and activates an
allocated desktop for control on the existing workspace host. Sessions qualify
launch, copy and detach by selected desktop; observers cannot activate a dormant
record. Two-runtime acceptance proves simultaneous controllers on separate
desktops, retained default-shell continuity, allocation replay and cross-target
session denial. The native binding and 490 Lua tests pass. This is not installed:
automatic public second-launch selection and executable acceptance remain pending.
The runtime's separate exact remote actor EXIT recovery gate still fails. See
[client state](CLIENT_STATE.md) for the source contract and limits.


The next source UI adds a compact connection dropdown to the existing workspace
label (mouse or F9). It separates the local Hive service, executing node, workspace
identity/readiness and durable display identity/size. Hive service information is
supplied by the trusted retained-supervisor bootstrap; unreported legacy sessions
show "Not reported". This is not remote-peer health or a physical-client identity.
The presenter performs no discovery or networking. Source/pack tests cover mouse,
Escape, F12 and a 42×12 terminal. Hive Manager keeps readiness in view at narrow
widths and moves addresses and full IDs to Details. The native UI build is installed globally and its executable acceptance passes,
including stable display identity after reconnect. Hive Manager recognizes explicit
native client-role metadata as display clients and does not query them as Bee
services. This metadata grants no authority; names alone never establish roles.
The full check for that installed UI revision passed Lua and storage gates, then
caught an F9 modifier regression: Alt+F9 opened the dropdown instead of minimizing.
The following source correction restricts the dropdown to unmodified F9.

The next Hive Manager safety fix binds an attachment confirmation to the exact
node, workspace, desktop, owner generation and mode shown in the question.
Selection or owner changes require a new confirmation; an unconfirmed proposal
cannot become a retryable pending operation. Source/pack regression checks pass.
Live desktop browsing/attachment in the app remains unavailable: the existing
catalog is admitted to native clients only. This fix grants no new access and
is now in the installed global build. Alt+F9 minimize and plain-F9 status pass
source/pack and executable checks. The corrected safety checkpoint has passed its full repository check
(493 Lua tests, 525 registry entries); the later session-identity follow-up is
being validated separately.
