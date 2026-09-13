# Docker preparation

`configuration.build` projects host-admitted image, resource limits, mount paths,
command and attempt labels into Docker daemon configuration, consumed directly
by the existing userspace Docker client.
It performs no I/O and grants no authority. It is internal preparation, not a
placement binding or a selectable Agent profile.

The admitting owner must resolve and authorize sources, check the actual image
and host sandbox capabilities, bind this projection to the attempt before driver
configuration rendering, and retain the resulting execution identity. Matching
labels and normalized paths do not prove ownership or filesystem containment.
Host writes remain with the existing materializer; driver configuration must use
the selected container-visible HOME.

The projection keeps the root read-only, drops capabilities, requires
no-new-privileges and a selected AppArmor profile, uses explicit
resource limits and network selection, and mounts only the private home plus
one to fifteen admitted mounts. Home and admitted host sources must not overlap:
mounting a source that contains private placement homes would expose credentials.
Mount targets cannot overlap each other, the private home target or `/tmp`.
Each admitted mount preserves its requested read or write access.

The config supplies no seccomp override, selecting Docker's daemon default.
Admission must verify that the daemon actually enforces the required sandbox;
config generation alone does not prove that. There is no intermediate policy
selector or second configuration translation.

The builder accepts the existing materializer's admitted `environment` map;
it does not read the host environment. It preserves values and generates HOME
and TMPDIR if absent, refusing values that disagree with the selected home or
`/tmp`. The final environment is bounded to 64 entries and 65536 bytes, with
16384 bytes per value, and sorted by name. Credential and gateway values belong
only in the create request, never in durable configuration or diagnostics.
The owner must perform the existing policy/credential/gateway admission before
supplying these values. This pure builder does not authorize variable names.
Broader profile
configuration, credential delivery, container-reachable MCP/hooks, durable
admission, reconciliation and full Agent terminal integration remain unfinished.
No container creation, driver startup, downloads or global installation occurs
through this library.

`inspection.decode` is the corresponding pure boundary decoder for a Docker
inspect object and a host-admitted expected identity. It requires the full
container ID, full image ID, `Config.Labels`, `State.Status`, `State.StartedAt`
and `State.ExitCode`; unrelated fields from Docker's larger inspect response are
ignored. Every expected label must still match, while extra daemon labels are
ignored and the returned map contains only expected labels. `created` requires
Docker's zero start timestamp and returns no `started_at`; `running` and
`exited` require a nonzero parseable RFC3339 timestamp and preserve its exact
text. An optional previously recorded `started_at` must match exactly, fencing
a same-ID replacement. The expected AppArmor profile must match Docker's
post-start `AppArmorProfile` for running and exited containers; this
corroborates the selected profile but does not authorize creation or start.
Only `exited` returns `exit_code`. Unsupported states are rejected, and
transport failures must be handled by the caller rather than passed to this
decoder as lifecycle observations.

The input is a strict object with `image` (local `sha256` image ID), `user`
(`uid:gid`), `network`, `apparmor`, `memory`, `nano_cpus`, `pids_limit`,
`command`, `home_source`, `home_target`, `mounts`, `working_directory`, optional
`environment`, and the
six attempt `labels`. `mounts` is a dense array of one to fifteen
objects, each containing only `source`, `target`, and `access` (`read` or
`write`). Bee bounds the home plus these mounts to 16 binds.
Legacy `workspace_source`, `workspace_target`, and
`workspace_access` fields are refused as unknown input.
The returned config uses the existing Docker field names. Unknown input is
refused; this is not a pass-through for arbitrary Docker options.

For a local daemon with access to Bee's host paths, sources and targets may use
the same absolute paths. The existing materializer and frozen driver paths can
then be reused unchanged. The compiled default keeps private homes under the
application state directory. Source overrides or a project containing that
state must still satisfy the private-home overlap checks. A remote daemon or
unshared Docker Desktop path needs explicit resource materialization; matching
strings alone do not establish that the daemon can access the same files.

Lua tests exercise command/mount projection and refusals. The component-boundary
check uses the reviewed userspace source with its real Lua HTTP client and a
private fake daemon, verifying exactly one create and inspection and no start:

```sh
make docker-configuration-check WIPPY=/path/to/runtime DOCKER_COMPONENT=/path/to/userspace/docker
```

This proof cannot establish host AppArmor support, actual sandbox execution or
managed Agent acceptance. Tests and daemon fixtures remain outside `src/`.
