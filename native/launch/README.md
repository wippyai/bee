# Native Bee launch

`NewLauncher(client, ownerCommand, prepareOwner)` is one compiled launch-preparer
component. Ordinary launch runs a foreground native client; explicit `start`
selects the host's headless owner command. The owner and its DesktopService are
separate host-selected boot components. Update/tooling/base operations retain
the runtime's existing paths. The installed global candidate uses this composition;
see [current acceptance](../../docs/FOUNDATION_STATUS.md) for its runtime pin and limits.

The foreground starts the same executable as a detached owner contender with
literal selected state/command arguments and the original project directory.
The child arbitrates through the runtime's actual application lock. A winner
prepares the native owner under that lock and publishes a new execution. A loser
authenticates the existing owner and reads its catalog without mounting a desktop.
A successful loser exit or changed descriptor lets the foreground attempt fresh
supervisor admission once. Hints and lock contention grant no access.

Startup publication has a 30-second deadline. Unchanged stale discovery does not
prove readiness; child failure never falls back to stale discovery. Invalid
discovery fails closed. Attachment/input are not replayed. The native session
separately bounds transport/supervisor readiness and requires explicit selection
when the catalog is ambiguous. Warm launches probe the runtime's existing `statelock.Acquire` lock and go
directly to authenticated attachment when it is busy. They create no contender
or owner log. A free probe releases the lock before spawning; the child still
arbitrates ownership under that same runtime lock, including races with other
launchers. Filesystem errors do not count as contention.

`Client.Attach` also directly supplies a runtime `LaunchPlan.Attach` callback. It
rejects unrelated operations/commands, unhandled arguments and invalid paths
before discovery. The callback runs before deployment/application data bindings.
`NewOwnerLauncher` exposes only explicit-start routing for host compositions that
do not select the automatic foreground route.

`StartOwner` separates OS process lifetime: null stdin, caller-owned regular log,
and a new session/process group. The automatic route creates an owner-only log
in the selected state directory and reports its path on failure. Client detach,
exit, cancellation and `OwnerProcess.Wait` cancellation do not stop an already
started owner. `Abort` explicitly force-stops the particular child; only fixture
cleanup currently uses it. It is not a public workspace shutdown operation.

## Acceptance

Run `make -C native client-launch-check MESH_RUNTIME=/absolute/reviewed/runtime`.
Race/vet covers routing, stale hints, child failure, cancellation, literal argument
preservation and independent OS process lifetime. The Linux subprocess proof
waits for the launcher to exit before the child writes evidence and checks that
the child has no controlling terminal. Windows flags exist but remain unverified.

The actual-source localowner composition additionally proves explicit detached
self-exec, runtime lock-busy attachment, automatic reuse of a retained Terminal,
and automatic cold startup from an empty state directory. The foreground has
an empty bundle, invalid data bindings and failing owner hooks so accidental
deployment/owner startup fails. See localowner's README for the source/toolchain
requirements. This proof still supplies fixture activation, naming/execute
policies and a headless wait entry. Production entry selection, executable assembly, embedded-default startup and
global-binary acceptance now pass in the assembled Bee candidate. Registry
history is preserved. Governed overlay activation is a separate subsystem; this
launcher neither admits edits nor implements publication.

Concurrent explicit-start acceptance holds the winning child in preparation for
one second under the real lock. The losing start waits for publication, performs
read-only owner verification and exits successfully; exactly one child remains
alive with the state lock. The pre-fix failure and passing race/vet are preserved
in the shared journal. No second lock or transport was added.

Signal-exit acceptance sends SIGTERM to the isolated foreground test process,
checks restoration of the physical terminal settings, then reattaches a fresh
client and reads the same retained shell variable. This required ordering
presentation cancellation before transport/actor retirement; canceling all of
them together raced detach and viewport revocation.

Ordinary launch immediately prints `Starting Bee…` when the runtime state lock is
free, or `Connecting to Hive…` when it is busy. The latter is a routing status,
not an authenticated readiness claim. Owner startup remains local on the free
path; no network discovery timeout precedes that decision. Catalog cancellation
before an attach request is reported as a canceled read, while uncertainty after
an actual attach or detach request remains intact.

`bee observe` selects the same attachment route with observation-only rights.
It requires an already-running Bee for the selected state directory and refuses
an absent Bee before creating an owner process, log or database. The runtime
lock is only a routing hint; native authentication and supervisor admission still
apply. Application arguments are refused. Ctrl+Q or Ctrl+] detaches this display
without affecting the controller or applications. This is local same-account
observation; external enrollment and public desktop selection remain separate.

Explicit selection is now implemented in the native source: `bee desktops`
prints the authenticated workspace/display catalog without creating a desktop
or controller grant. `bee attach WORKSPACE DISPLAY` requests control of exactly
that pair; `bee observe WORKSPACE DISPLAY` requests observation of exactly that
pair. Plain `bee observe` retains default selection. These commands use the
selected local state directory and refuse an absent Bee; they do not provision
a node or enroll a remote machine. IDs come from the catalog, not list position.
Explicit refusal or uncertainty never selects or allocates another display.
The display picker UI and remote enrollment remain separate unfinished work.
Executable acceptance is pending; these commands are not in the global build yet.

## Project-scoped launch candidate

The compiled desktop now selects implicit application state from the canonical
launch directory before looking up a running node. State lives beneath the
application's existing state root in `projects/<SHA256 of canonical directory>`.
Two different folders therefore have independent locks and stores; a symlink
alias selects the same project. The detached owner retains the original project
working directory and receives the selected state explicitly, so it cannot
remap that state a second time. Explicit `--state-dir` remains authoritative;
existing application databases are preserved. Runtime tooling and update state
selection are unchanged.

`bee client` is an explicit attachment-only route, optionally taking a workspace
and display ID pair. It refuses if the selected project has no running Bee.
Ordinary `bee` starts that project's node plus the current physical display,
or adds a display when its project node is already running. `bee start` remains
headless. Cross-project client selection still needs the Hive selection route.

This is an uninstalled candidate. The launch race/vet checks cover independent
project locks, canonical aliases, explicit-state preservation and absent-node
client refusal. Full two-project executable acceptance, distinct Bee-node names,
same-account Hive enrollment/joining and terminal working-directory assertions
remain required; project state selection alone does not establish those facts.

The project-owner preparation route also derives its native node name from the
canonical selected state directory, retaining the host label as a prefix.
This distinguishes two local projects and keeps each name stable across owner
restarts. The ordinary local-owner component still accepts an explicitly selected
node name for host compositions and fixtures. Transport keys and owner execution
IDs remain fresh per invocation; a stable name does not retain old grants.
