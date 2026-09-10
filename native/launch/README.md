# Native Bee launch

`NewLauncher(client, ownerCommand, prepareOwner)` is one compiled launch-preparer
component. Ordinary launch runs a foreground native client; explicit `start`
selects the host's headless owner command. The owner and its DesktopService are
separate host-selected boot components. Update/tooling/base operations retain
the runtime's existing paths. This composition is not installed in global Bee.

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
policies and a headless wait entry. Production entry selection, executable
assembly, overlay preservation and global-binary acceptance remain unfinished.

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
