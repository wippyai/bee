# Existing-container PTY attachment

This optional Go component supplies the runtime's existing `exec.PTYProcess`
interface for a container created and started by its admitting component. It is
not registered as a Lua module or wired into Bee's Agent application yet.

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
that extension point is separately proven. Lua permission admission, actual Bee
terminal-grant acceptance, profile/sandbox validation and the container gateway
remain unfinished. This directory must not be registered broadly to bypass those
boundaries.

Run isolated race tests and vet through the native Makefile:

```sh
make -C native docker-attachment-check DOCKER_RUNTIME=/path/to/reviewed/runtime
make -C native docker-attachment-check DOCKER_RUNTIME=/path/to/reviewed/runtime DOCKER_TEST_TAGS=integration
```

The integration case requires Docker and an already-local `alpine:latest`; it
never pulls. It creates and cleans up only its own fixture. It proves attachment,
input, resize and exact-container exit, not the complete hardened Bee profile.
