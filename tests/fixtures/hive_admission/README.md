# Supervisor host admission fixture

Run from the Bee repository with a candidate containing the host-check patch:

```sh
make hive-admission-check NATIVE_WIPPY="$PWD/.wippy/bin/bee-wippy-host"
```

The Go runner stages only this fixture in a disposable directory, runs strict
lint, and launches the command on its terminal host. It never loads Bee's
production Hive module or opens a workspace database.

A worker coordinator assigns a minimal scope to an attacker actor. The actor
can execute one harmless entry, but is explicitly denied the supervisor host.
All five direct spawn/exec variants and two context-bound spawn forms must
report target-host permission denial while the host is empty. The coordinator
then starts an authorized child there, authenticates its reply by sender PID,
and observes its clean exit before repeating the negative phase. Reply and exit
may be observed in either order; there are no timing sleeps to enforce ordering.

The patched candidate passes. The unpatched baseline fails because the attacker
is admitted during phase one. Native Go regressions separately check the exact
PermissionDenied error kind. The runtime patch adds checks to the three direct
linked/monitored variants; context-bound checks already existed.

This is a local actor-level prerequisite. It does not prove production supervisor
composition, process-function bridge restrictions, peer hello, enrollment,
workspace discovery or remote Terminal launch.
