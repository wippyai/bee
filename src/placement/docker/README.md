# Docker preparation

`configuration.build` projects host-admitted image, resource limits, mount paths,
command and attempt labels into the existing userspace Docker narrow config.
It performs no I/O and grants no authority. It is internal preparation, not a
placement binding or a selectable Agent profile.

The admitting owner must resolve and authorize sources, check the actual image
and host sandbox capabilities, bind this projection to the attempt before driver
configuration rendering, and retain the resulting execution identity. Matching
labels and normalized paths do not prove ownership or filesystem containment.
Host writes remain with the existing materializer; driver configuration must use
the selected container-visible HOME.

The projection keeps the root read-only, drops capabilities, requires
no-new-privileges, default seccomp and a selected AppArmor profile, uses explicit
resource limits and network selection, and mounts only the private home plus
one to fifteen admitted mounts. Home and admitted host sources must not overlap:
mounting a source that contains private placement homes would expose credentials.
Mount targets cannot overlap each other, the private home target or `/tmp`.
Each admitted mount preserves its requested read or write access.

Only HOME and TMPDIR are generated, matching the existing narrow contract.
Arbitrary environment fields are refused, not discarded. Broader profile
configuration, credential delivery, container-reachable MCP/hooks, durable
admission, reconciliation and full Agent terminal integration remain unfinished.
No container creation, driver startup, downloads or global installation occurs
through this library.

The input is a strict object with `image` (local `sha256` image ID), `user`
(`uid:gid`), `network`, `apparmor`, `memory`, `nano_cpus`, `pids_limit`,
`command`, `home_source`, `home_target`, `mounts`, `working_directory`, and the
six narrow admission `labels`. `mounts` is a dense array of one to fifteen
objects, each containing only `source`, `target`, and `access` (`read` or
`write`). The home plus these mounts therefore stays within the userspace
16-bind limit. Legacy `workspace_source`, `workspace_target`, and
`workspace_access` fields are refused as unknown input.
The returned config uses the existing Docker field names. Unknown input is
refused; this is not a pass-through for arbitrary Docker options.

Lua tests exercise command/mount projection and refusals. The component-boundary
check uses the reviewed userspace source with its real Lua HTTP client and a
private fake daemon, verifying exactly one create and inspection and no start:

```sh
make docker-configuration-check WIPPY=/path/to/runtime DOCKER_COMPONENT=/path/to/userspace/docker
```

This proof cannot establish host AppArmor support, actual sandbox execution or
managed Agent acceptance. Tests and daemon fixtures remain outside `src/`.
