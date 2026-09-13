# wolfy-j/bee-placement-docker-daemon

This optional component provides `bee.placement.docker.daemon:daemon`, a thin typed
lifecycle adapter over the existing `userspace.docker:docker_client`. It has no
placement database, attempt state, cleanup worker, process execution or native
fallback. The admitting placement owner remains responsible for intent,
transitions, reconciliation and cleanup.

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
