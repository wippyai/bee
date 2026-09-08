# Foundation status

Bee is a local terminal desktop with four on-demand default applications:
Terminal, Settings, Process Manager and Test Status. A fresh workspace opens no applications;
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

## Ownership

Public local launch uses the host/client split. Full source/pack and standalone
acceptance pass. Older selected deployments retain their code until explicitly
changed; `bee --base` selects the executable's embedded baseline and preserves
application databases.

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
piped execution. A complete headless workspace profile remains unimplemented.
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

`make setup` builds the commit and checksum-verified patch in `runtime/lock.json`.
It disables ambient Go workspaces and never consumes a checkout's dirty files.
The patch preserves the native startup, full-width surface and scheduler shutdown
fixes needed by this desktop. These runtime files retain their upstream MPL-2.0
license; Bee's own source is MIT. The runtime patch should move upstream before
a public stable release; carrying it here makes this development checkpoint reproducible.

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
targets return an error without executing locally. Mixed-workspace composition and remote
attachment are not implemented.
Apps checkpoint through their broker; a successful receipt follows database commit.
See [storage](STORAGE.md) and [application contracts](APPLICATION_CONTRACTS.md).

`make check` runs typed lint, pure model/protocol/lifecycle tests, import and loaded
registry audits, and real source/pack terminal acceptance. Native terminal tests
exercise execution, PTY isolation, input, resize, interruption, rejoin, color fill,
close and registry/TTY access denial. Acceptance uses disposable stores and never
modifies a user's workspace history. CI runs the same setup and checks.

## Next boundaries

The local native thread journal and Test Status app are implemented. Explicit
launch arguments select a thread and optional idempotent run ID. A standalone
worker finishes while its view is closed; source and pack acceptance verify
reopening and cold replay. The isolated Lua subscriber fixture remains separate.
Production views currently poll; crash-safe job scheduling, dynamic membership
and durable subscriptions remain future work. See [threads](THREADS.md) for the
implemented API and limits, and [workspace attachments](WORKSPACE_ATTACHMENTS.md)
for the proposed identity split.

The shell remains the delivery focus. Hub installation, authorized overlay editing,
MCP, AI drivers, native binary packaging and service/run
lifetimes are separate subsystems, not unfinished responsibilities of the presenter.

The first resource subsystem should own a workspace's named filesystem roots:
a stable resource ID, provider, authorized root, display name, and entry points.
Terminals, file views, Docker mounts and watchers reference those IDs instead of
embedding host paths into desktop state. Discovery may propose projects; it must
not authorize a root automatically. Native paths, container roots and virtual
providers need explicit resolution and containment checks at the provider boundary.
The terminal currently starts in the runtime's working directory; a resource binding
will replace that implicit choice once this subsystem exists.
