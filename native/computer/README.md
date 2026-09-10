# Computer owner: experimental native boundary

This risk spiral connects the Windows computer driver to Bee's native runtime
identity and permission contexts. It is a callable Go package with Windows VM
acceptance, not an activated Lua module, service, public CLI or Hive operation.
Nothing in the normal Bee launcher changes.

Trusted host composition constructs exactly one `Owner` per selected OS seat,
with a fixed executable, local node ID, exact security resource and stable private
recovery directory (`New(executable, node, resource, recoveryDirectory)`). For example
`bee.computer:console`. The executable dispatches `--bee-computer-driver` directly
to `driver.Run()` and dispatches other private input roles through
`driver.InputRole(role)`. Every role exits when its handler returns. Parent,
recovery guard and injector use the same binary;
the test executable proves this role dispatch. Starting the child directly grants
no runtime permissions and provides no sandbox against the local OS account.

`Open(processContext)` requires `bee.computer.control` on that exact resource.
`Lease.Do(callerContext, request)` independently checks `bee.computer.observe`
or `bee.computer.act`, the native frame PID and security actor. An opaque lease
cannot be used by a sibling actor or a foreign node. An empty context denies even
if the runtime globally allows incomplete security contexts. Operation permissions
are re-evaluated for every request; control admission does not imply observation
or input. The trusted contexts must come from the native caller, not a wire PID.

The owner selects IPC request IDs and the endpoint binding. The child supplies a
random 128-bit incarnation and the Windows token AuthenticationId (logon LUID),
qualified with the WTS session number and interactive-logon timestamp. These are descriptions, not bearer tokens.
Driver restart creates a different incarnation; old lease handles and frames fail.
An observed desktop-access failure ends the child permanently. Restoring desktop
access requires a fresh open and observation. A retired child occupies its seat
until process exit is observed, including after cancellation or transport failure.
`Revoke(ctx)` and `Stop(ctx)` join driver exit. If persisted input remains
unresolved they return `ErrRecovery`; driver exit does not imply seat recovery.

There is one in-flight operation and no application request queue. Concurrent
calls return Busy. Requests are at most 64 KiB; PNG responses at most 16 MiB;
actions are capped at 32. PNG bytes follow their JSON header without base64.
Operations have a five-second deadline; the lease and child last at most 30 seconds.
Cancellation kills the driver endpoint and closes its guard control pipe. The
guard survives to stop/join its injector and attempt release-only cleanup. A
failed transport returns an uncertain outcome
and is never replayed. Frame consumption precedes input effects. These bounds
are not a cross-node bandwidth or congestion-control implementation.

The Windows driver checks the active console, WTS session-lock state and accessible
Default desktop before requests/actions and every 250 ms while idle. A separate
locked OS thread owns a hidden window, WTS notifications and an out-of-context
desktop-switch hook. Observed transitions permanently retire the child, even
when the desktop switches back before the next poll. PNG release rechecks both
access and lease expiry after encoding. The native proof targets Windows 11;
the historical Windows 7 inverted WTS lock flags are not supported.
An actual 122.6 ms away/back desktop transition retired the old child and lease,
rejected the old frame on a fresh endpoint, and allowed fresh capture. A separate
actual workstation-lock test retired access and rejected fresh opening; its
647.5 ms total includes the OS transition and fresh-denial check, not a revocation
latency guarantee. Earlier UAC evidence remains separate. Driver startup in
Session 0 remains unsupported. Windows service-to-interactive-user bootstrap,
actual logout/login recovery, RDP and multiple displays remain unproved.
Windows key actions now accept bounded complete chords, for example
`CTRL+SHIFT+END` and `ALT+TAB`, using CTRL/SHIFT/ALT/META modifiers and
supported named or A–Z/0–9 virtual keys. Chords are layout-dependent; Unicode
text remains separate. Existing held modifiers/buttons or transaction keys cause
refusal without releasing them. Returned partial SendInput submissions trigger
release-only cleanup when the desktop remains accessible and retire the endpoint;
cleanup submission is not a guarantee that all held state cleared. The original
action is never replayed. Input overlap is handled conservatively: each transaction has a random native
event tag. The guardian's dedicated thread monitors keyboard and mouse hooks;
foreign events pass through and trigger injector termination and quarantine.
After collision, only this transaction's tagged events are suppressed, including
cleanup releases, to preserve foreign-held input. The detector retains only
collision flags. It is best effort: Windows can silently remove timed-out
low-level hooks, so it is not guaranteed exclusive desktop control. Use dedicated
automation sessions; the OS user retains authority. The guard has a two-second input
deadline and owns its injector in a private Windows kill-on-close job, assigned
before sending the input plan. Killing the guard terminates the injector but can
leave input held; this is an unresolved recovery outcome. Focus management
remains unimplemented. A native injection receipt is not application completion.

The Windows driver test executable independently verified native EDIT selection
with CTRL+HOME and CTRL+SHIFT+END, exact Unicode replacement, and real Control-down
followed by partial-return cleanup. Fault tests cover all partial return counts for
chords, drags and Unicode, existing-held-state refusal and desktop-loss cleanup
refusal. Enable the VM-only test with `BEE_COMPUTER_INPUT_TEST=1`; build the driver
package separately using `go test -c ./driver`. The combined owner/driver/guard Windows test verified native selection and
Unicode replacement, clearing of the matching pending record, and fresh-owner
admission. Guardian tests independently observed real Control-down and release
on disconnect/expiry, and kernel injector termination on guardian death. The last
case retained held Control until explicit observer cleanup; it is not automatic
recovery. Exact evidence and remaining gates are in Wippy's computer-use ledger.

Before each action the owner commits a pending token using the existing privatefile
helper. A matching clean driver result clears that token. Transport uncertainty,
unknown outcomes or failed persistence retain quarantine across owner/process
restart. Replacement Open and Revoke consult the same state. Host composition
must map each physical seat to one stable directory; choosing another directory
or deleting the record is not a recovery operation. Records bind node/resource
and version; corrupt data and stale completion tokens deny. The directory has
OS-user protection, not a sandbox against other same-account processes. Windows
process-exit persistence passed; power-loss durability is not established.

`Owner.RecoverAfterLogon(ctx)` requires `bee.computer.recover` on the exact
resource, separately from control. It performs no sign-out or input injection.
It requires a later WTS interactive logon and a changed token logon identity;
if Windows assigned a different session number, the previous session must be
absent from the WTS inventory. The current console must be accessible and no
key/button may be held. RunAs alone and lock/unlock cannot satisfy the logon
replacement requirement. Missing older session evidence fails closed. This
operation is a native host seam, not a public Lua or Hive reset tool.

Windows acceptance retained a pending record in session 1, denied same-logon
recovery, actually signed the isolated user out, verified no user remained,
then signed into session 2. Ordinary Open remained denied until explicit recovery
succeeded; fresh capture then returned 711,978 bytes. The session replacement
and recovered capture were real; the pending marker for this two-run test was
seeded deliberately. Earlier held-input interruption evidence remains separate. The caller closes guardian pipes after three seconds, allows 750 ms for exit,
then forces termination and waits at most another 500 ms. Forced termination
always reports uncertainty and retains quarantine. A Windows test that stalled
the guardian before accepting input verified termination and unresolved return
in 3.756 seconds. This is measured acceptance, not a scheduling guarantee.
Hardware-origin and foreign-injector collision acceptance passed; combined
crash/desktop-transition evidence is described below. The current quarantine prevents
new admission; it does not claim these unresolved recovery cases are complete.

A future Lua dispatcher must bind the lease to the actual process lifetime and
execution epoch, cancel it on actor exit/exec, and check both relevant security
contexts before yielding to an off-scheduler worker. This package tests real native
frame/security APIs using explicit test scopes; it does not yet prove that Lua
adapter or engine-exec lifecycle. Hive must reuse its authenticated supervisor
admission and destination owner; no network listener, new mesh or peer identity
system is introduced here. Resource metadata cannot grant access.

## Checks

From this directory:

```
make check
make windows-check TEST_EXE=/tmp/computer.test.exe
```

On Windows, run the test executable as the standard interactive user. Its child
role uses real GDI capture, not a mock. Tests cover denied/missing/wrong-resource
permissions, foreign nodes, sibling actors, read-only input rejection, revocation,
restart, old-frame rejection, caller cancellation and driver crashes. Linux uses
an explicit protocol fixture and additionally tests stalled-transport cancellation;
it does not exercise an X11 backend. `TestDesktopLoss` needs the explicit test-only
`BEE_COMPUTER_DESKTOP_TEST=1` environment and an external secure-desktop transition
after it writes `desktop.ready`. Do not enable it in unattended generic CI.

The standalone Go test runner, rather than the full Bee Windows distribution,
was deployed to the evaluation VM. Windows builds and vet pass without cgo.
The latest full repository `make check` stopped at three Lua lint errors in
Hive supervisor ingress. Earlier blank-terminal UI failure and focused rerun
evidence remain in the research ledger. This unactivated package does
not claim a passing foundation suite, and no unrelated UI code was changed.

Bee owner code and tests are MIT. The adapted shared protocol and Windows backend
retain their Wippy research MPL-2.0 headers and the adjacent MPL license text.
No new third-party Go dependencies were added.

Controlled VM-only tests: `BEE_COMPUTER_RAPID_TEST=1` enables
`TestRapidDesktopTransition`; `BEE_COMPUTER_LOCK_TEST=1` enables
`TestSessionLock`, which deliberately leaves the workstation locked and must
run separately from normal tests. Restore the console session afterward.
The source API for the lock flag is Microsoft's
[WTSINFOEX_LEVEL1_W](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/ns-wtsapi32-wtsinfoex_level1_w).
Lifecycle code/tests are MIT; adapted protocol/backend files retain MPL-2.0.

Combined held-input interruption acceptance requires an explicit `computerfault`
build tag in addition to `BEE_COMPUTER_INPUT_TEST=1` on the isolated Windows VM:

```
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go test -tags computerfault -c -o /tmp/computer-interruption.test.exe .
```

The acceptance-only driver file installs a down-prefix-and-stall callback and
records process IDs for the test observer. Default Windows source selection
excludes that file. The observer pins live process handles before faults. Actual
caller cancellation and driver kill released Control in about 18 ms in one run;
an actual desktop round trip ended both processes and left Control up after
2.16 seconds. All cases returned uncertainty and denied replacement admission.
The desktop case does not attribute key-up to the guard: OS desktop switching
can change key state. Existing real shortcut and quarantine tests passed in the
same acceptance executable. These tests do not resolve quarantined seats.

The hardware acceptance used QEMU's emulated keyboard after independently
observed agent Control-down. Windows reported a non-injected collision; both
agent input processes exited and Control remained held until QEMU released it
naturally. No observer key-up satisfied that assertion. The external coordination
uses a test-only extended lease; the normal two-second suite passed separately
on the same executable. See Microsoft's documented
[low-level hook timeout limitation](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc).

Spiral 4 is verified for this experimental Windows native slice. It does not
activate Lua/Hive, provide multi-display or RDP support, establish power-loss
storage durability, or guarantee exclusive physical desktop control. The latest
full repository check still stops at three unrelated Hive ingress lint errors.
