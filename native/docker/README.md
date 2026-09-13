# Existing-container PTY attachment

This optional Go component supplies the runtime's existing `exec.PTYProcess`
interface for a container created and started by its admitting component. It is
not registered in the public launcher or wired into Bee's Agent application yet.

`NewModule(daemonRef, client)` provides the typed `docker_pty` Lua module. The host
selects the daemon client and stable reference; Lua cannot supply a daemon URL or
socket. `docker_pty.attach({container_id, image_id, started_at, labels})` requires
an authenticated actor and scope, then checks `docker.attach` on
`<daemonRef>/<full-container-id>`. Policy metadata includes `image_id`, `started_at`
and `labels`; metadata is a requested constraint, not proof of ownership. The
host must grant access from its own admitted records, never merely from supplied
labels. The operation returns the existing runtime `exec.Process` handle without
daemon I/O. Its `attach_terminal()` must run in the actor holding the terminal
grant; the normal runtime method owns the resulting terminal session.

`New` accepts the caller-owned Docker client and an admitted full container ID,
actual image ID, execution start timestamp and expected labels. It copies the
labels and performs no daemon I/O. `Start` verifies those facts, attaches to the
running PTY, and verifies them again before publishing the connection. A failed
recheck closes that connection. No method creates, starts or removes containers.
Input, resize, signals and waiting use the same exact container ID. Resize and
signals recheck identity; finished handles refuse further control. `Stop`
releases this handle and its connection without destroying the container.

The admitting component must authorize the daemon and container before calling
`New`; supplying matching labels is not authorization. Docker does not provide
an atomic compare-and-signal operation. The lifecycle owner must serialize its
own restart/control operations; these checks cannot fence a daemon administrator
changing execution between an inspection and control request. Initial log replay
is enabled, but full cold screen recovery is not established.

The runtime's public Lua `exec.NewProcess` constructor can carry this interface;
that extension point is exercised by the module. Scope refusal tests and an
integration test with actual runtime frames, a native viewport grant and Docker
pass. A child frame inherits the security scope but cannot inherit the parent's
terminal port. This is not Bee broker/placement acceptance: its host binding,
admitted-record policy, profile/sandbox validation and container gateway remain
unfinished. This directory must not be registered broadly to bypass those boundaries.

A fixed runtime expression policy can constrain attachment to a selected daemon
and the authenticated principal's owner label without embedding each newly
allocated container ID in the spawn scope. The Lua module test exercises that
policy with the actual expression evaluator and a fake daemon: a different
principal or daemon is refused without I/O; a forged owner label fails inspection
before attachment; matching observed ownership reaches the attach operation.
The fixture deliberately refuses the stream there. This is principal-level
authorization, not isolation between sibling apps under the same principal.
The trusted Bee attempt owner must still validate the selected durable attempt;
the policy does not consult that record or prove full placement admission.

Run isolated race tests and vet through the native Makefile:

```sh
make -C native docker-attachment-check DOCKER_RUNTIME=/path/to/reviewed/runtime
make -C native docker-attachment-check DOCKER_RUNTIME=/path/to/reviewed/runtime DOCKER_TEST_TAGS=integration
```

The integration case requires Docker and an already-local `alpine:latest`; it
never pulls. It creates and cleans up only its own fixture. It proves attachment,
input, resize and exact-container exit, not the complete hardened Bee profile.
A real restart case also keeps the same container ID while changing its execution:
the old handle cannot signal or resize it, old admission cannot reattach, and a
freshly observed execution can attach and resize. This tests completed restart
fencing; it does not eliminate Docker's inspect/control race described above.
