# wolfy-j/bee-placement-docker-daemon

This optional component provides `bee.placement.docker.daemon:daemon`, a thin typed
daemon adapter, and the `bee.placement.docker` placement lifecycle over the
existing `userspace.docker:docker_client`. It has no
owned database or native fallback. The placement lifecycle uses the shared
native placement receipt store and owns its Docker transitions, reconciliation
and cleanup; the daemon adapter owns no attempt state or process execution.

The placement binding is `bee.placement.docker:binding`; its public methods are
registered in the component's `lifecycle` namespace and use the shared native
placement receipt store. The daemon namespace owns only the typed Docker socket
adapter.

The host selects `bee.placement.docker.daemon:daemon_ref`, which must link to one
registry resource containing an absolute Unix `socket_path`. The adapter never
discovers a daemon or reads ambient Docker settings. Registry metadata describes
the binding; host admission and policy grant the actual socket access.

The source manifest imports `bee.placement.docker:inspection`,
`bee.threads.records:bounds` and `userspace.docker:docker_client`. These
correspond to the `bee/placement-docker`, `bee/threads` and
`userspace/docker-client` package dependencies. They are not artifact-resolved
in this revision: the userspace dependency is unpublished, so the component
is kept out of Bee's default pack. The repository fixture composes this source
with the reviewed local userspace client at commit `9d3c310` and the existing
pure placement inspection decoder.

`capabilities()` reads `/info` through the same selected daemon connection. It
reports Linux, seccomp, AppArmor and memory/PID/CPU quota support separately;
missing or non-boolean limit fields never report support. Security option names
match whole properties, and malformed or unavailable responses fail. These are
daemon support facts, not proof that any container has the admitted sandbox.

Recovery bounds the listing to 64 candidates and establishes one exact name
before inspecting it. Malformed candidates and duplicate exact names retain
uncertainty even if another candidate has valid labels.

Create, start, inspect, stop and remove validate full IDs, expected labels and
the AppArmor profile when explicitly selected. An omitted AppArmor requirement
uses daemon defaults; `unconfined` remains invalid. `recover_create` is a read-only lost-reply
recovery: it lists the exact deterministic name, re-inspects candidates and
returns a result only when exactly one candidate has the expected image, labels
and name. Zero, multiple, malformed, absent and transport outcomes remain
uncertain; recovery never creates or restarts a container. Mutating calls
receive one validated follow-up inspection; a transport error remains unknown.
Removal reports success only after a confirmed Docker 404. The adapter does not claim to validate the full
sandbox configuration; the host-authorized placement path must supply the
configuration produced by `bee.placement.docker:configuration`.

The component source is linted and exercised by the repository fixture:

```sh
make docker-daemon-check \
  WIPPY=/path/to/runtime \
  DOCKER_COMPONENT=/path/to/userspace/docker-client
```

This is a protocol and boundary proof over a private fake Unix daemon. Managed
Agent Docker launch, host AppArmor support, real sandbox execution and package
publication remain pending.

## Registered lifecycle acceptance

`make docker-lifecycle-check WIPPY=/path/to/runtime
DOCKER_COMPONENT=/path/to/userspace/docker-client DOCKER_IMAGE=sha256:...`
composes the actual lifecycle namespace with Bee and uses an already-local image
containing `/bin/sh` and `sleep`. It creates disposable state beneath the current
user's home, without reading login files, and runs with container networking off.

The test proves prepare/replay, attachment, start and exact container identity,
then exits Bee and boots again against the same placement database. The same
container execution survives, a new attachment fences the old recipient, and
stop/cleanup confirms removal. Foreign ownership and ordinary-caller access to
internal reconciliation are refused. Failure cleanup only targets the fixture's
unpredictable attempt label.

Fixture setup has host authority, but every lifecycle operation runs through a
caller scope containing only the public function targets. The caller cannot read
the placement database directly. Service entries supply their own store,
configuration, credential and daemon permissions. The default socket policy
refuses access; the fixture host selects its exact socket before starting.

The lightweight Docker placement component ships the Agent's native attachment
policy. It permits only the canonical native daemon reference
`bee.placement.docker.daemon:daemon_ref` and a matching authenticated owner label.
The native module still verifies the actual container image, labels and start
identity on attachment. The host must configure `bee.docker.reference` to that
reference, `bee.docker.host` to the same Unix socket selected by the daemon
adapter, and the optional component's `socket_policy` to allow only that socket.
The service scope contains no `exec.run` permission.

The native boot acceptance uses the production attachment policy and proves
foreign-owner rejection before daemon I/O. Agent menu/PTY launch,
credential/MCP delivery and retained conversation recovery remain unverified.
The lifecycle fixture's identity-preserving home mount also does not prove
configuration delivery under translated home paths.
