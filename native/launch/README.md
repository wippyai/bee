# Native Bee launch

`NewLauncher(client, ownerCommand, prepareOwner)` builds one compiled `app.Host`.
Ordinary launch runs a foreground native client; explicit `start` selects the
host's headless owner command. The owner and its DesktopService are separate
host-selected boot components. The runtime's own verbs (`update`, `recover`,
`wippy`) keep the runtime's paths; `Plan` returns an empty plan for them. The
host's `Plan.Prepare` is the preparation the runtime calls after taking the state
lock and whose close runs after runtime shutdown, before unlock.

The foreground starts the same executable as a detached owner contender with a
literal `--state <dir> run start` line and the original project directory.
The child arbitrates through the runtime's actual application lock. A winner
prepares the native owner under that lock and publishes a new execution. A loser
authenticates the existing owner and reads its catalog without mounting a desktop.
A successful loser exit or changed descriptor lets the foreground attempt fresh
supervisor admission once. Hints and lock contention grant no access.

Startup publication has a 30-second deadline. Unchanged stale discovery does not
prove readiness; child failure never falls back to stale discovery. Invalid
discovery fails closed. Attachment/input are not replayed. The native session
separately bounds transport/supervisor readiness and requires explicit selection
when the catalog is ambiguous. Warm launches ask `app.Owned` about the runtime's existing application lock and
go directly to authenticated attachment when it reports an owner. The probe
creates nothing, so an absent state stays absent. A free state proceeds to spawn;
the child still arbitrates ownership under that same runtime lock, including
races with other launchers. Filesystem errors do not count as contention.

The host runs `Client.Attach` through `Plan.Run`, so the runtime invokes it
without opening the application state, deployment or data bindings. It rejects
reserved verbs, unrelated commands, unhandled arguments and invalid paths before
discovery. `NewOwnerLauncher` exposes only explicit-start routing for host
compositions that do not select the automatic foreground route.

One ordinary invocation selects the host's display client. `bee` alone attaches
and, with no owner published, starts one. `bee NAME [ARGS]` attaches and submits
that command inside the desktop. `bee client`, `bee observe` and
`bee attach WORKSPACE DISPLAY` never start a node, and `bee desktops` lists the
selected Bee's durable desktop identities. `bee start` keeps the explicit
headless owner route, and an argument containing `:` keeps the runtime's own
application entry for recovery and development launches.

`CanonicalProject` resolves the launch folder through symlinks so one project
keeps one native node identity. `ProjectStateDir` assigns one runtime state
directory per canonical project under the state the model resolved for the
executable, and
`DefaultProjectStateDir` adds the upgrade rule: the first canonical project
opened against a root that already holds Bee state is bound to that root by one
protected receipt, and every later project uses its digest-qualified directory.
No database is copied or removed, so a previous executable can still use the
root. A legacy root that a Bee is currently running refuses the upgrade instead
of splitting live state. An explicitly selected state directory never enters
this helper.

`AttachOnly` marks an explicit display client. It decides from published
discovery alone, so it creates no state directory and never contends for the
owner lock; with no published owner it reports that none is running.

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
assembly, embedded-default overlay preservation and global-binary acceptance
now have passing standalone checks. Remote process EXIT delivery and reliable
cleanup after abrupt client death remain failing runtime gates.

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
