# Native launch attachment

The compiled host selects `Client{Command, Mode, Selection, Stdin, Stdout}` and
installs its `Attach` method as `LaunchPlan.Attach`. Wippy calls that method only
when its actual application lock is busy, before configuring application data or
opening the deployment. Bee uses the selected state directory's protected native
discovery directory and the existing session/admission path. Lock contention
alone authorizes nothing; the supervisor still admits the fresh native actor.

The adapter rejects base recovery, update/runtime operations, different commands,
unhandled arguments and relative state paths. The caller owns physical streams
and signal cancellation. It does not start an owner or retry input.

`make -C native client-launch-check MESH_RUNTIME=/absolute/reviewed/runtime` checks
request rejection with race/vet. The actual-source local-owner composition test
also calls `application.Run` through this adapter while a separate owner holds
the lock: retained shell state is readable and Ctrl+] detaches. Its deliberately
invalid data binding and failing owner-preparation callback prove those paths are
not reached. See the localowner README for that test's runtime/source requirements.

This is not yet registered in the global executable. First-owner background
startup and the complete public command routing remain unfinished.

`StartOwner(ctx, request, log)` now supplies the process-lifetime half of first
startup. It invokes this executable with literal selected state/command arguments
and the `start` route, preserves the project directory, and starts a separate OS
session/process group. Stdin is null and output uses a caller-owned regular log
file, so foreground pipes and terminal ownership cannot keep the child attached.
The caller must provide a protected log; this function does not create one.

An already canceled start creates no process. Once started, observing/canceling
`OwnerProcess.Wait` does not kill the owner. The launching process reaps the child
while it lives; after launcher exit normal OS orphan handling applies. Child
creation is not readiness, and does not establish lock ownership or admission.
The Linux subprocess proof waits for the launcher to exit before the child writes
its evidence, checks independent process group/no controlling TTY, then allows
the child to finish. Windows has a detached-process implementation but no runtime
acceptance yet. The native explicit `start` routing is now implemented and tested against a
host-selected fixture command. Production entry selection, readiness/error
handling, and automatic first-launch composition remain unwired. Do not install
this as the public launcher until those checks pass.

`NewOwnerLauncher(publicCommand, ownerCommand, prepareOwner)` provides the single
native launch-preparer component for explicit `start`. It selects the supplied
headless command and clears the consumed argument; the runtime subsequently
invokes owner preparation under its existing application lock. Base start and
extra arguments are rejected. Update/tooling and ordinary launches are left
unchanged. The host separately installs the owner and its DesktopService.

The actual-source owner test now invokes `StartOwner`, re-enters the same binary
through the real standalone argument parser, selects the headless fixture entry,
then attaches a fresh physical client through the runtime lock-busy callback.
It proves retained Terminal state and Ctrl+] detach. The fixture still supplies
activation, naming/execute policies and the headless wait entry; it is not proof
of public production composition.
