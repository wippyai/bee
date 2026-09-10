# Foundation status

The global candidate installed September 10 now uses the native owner/client
launcher. Ordinary `bee` loads embedded code with shared registry history and
attaches through the same-machine native mesh. Ctrl+Q and Ctrl+] detach the
physical client while retaining its owner and applications. Standalone startup,
selection/copy, scrolling, explicit-detach reconnect and old-binary upgrade checks
pass. Warm launch now reuses the existing runtime lock and skips an extra owner
process; one standalone probe reached the retained desktop in 0.204 seconds.
Abrupt client death now has a standalone regression: after a 40-second native
node-departure observation interval, a fresh client rejoins the same retained
shell. Bee's supervisors handle existing LINK_DOWN events and revoke the
attachment without terminating the owner or declaring remote process completion.
The isolated owner-service trace has no failures and passes race/vet. Immediate
exact-actor EXIT while transport remains live is still a failing runtime gate.
The current frozen source now passes one uninterrupted `make check`, including
484 Lua tests, source/pack architecture at 517 entries, storage and subscription
restart checks, all desktop/client/launcher/recovery gates and the bundled apps.
The 16-window load check exited in 367 ms. Both previously intermittent startup
failure points passed without increasing time limits; their causes remain
unexplained, so this run is not a claim that those intermittent failures are fixed.
Evidence: `/tmp/bee-command-foundation-check-r2.log`.
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
Hive Manager refreshes supervisor lookup, membership and owner telemetry. A failed
lookup is shown as **Hive supervisor unavailable** with its reason; it does not
infer that Hive is disabled or that enrollment would repair the failure. A found
supervisor is reported separately from each peer's reachability and desktop
availability. Detailed startup phases require an authoritative lifecycle source.
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
