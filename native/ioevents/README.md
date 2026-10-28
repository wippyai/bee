# I/O events

This Bee-owned native component adds `ioevents` to Wippy. It uses the MIT-licensed
Syncthing notify backend, pinned in the parent Go module. The Go service tests
cover real file notifications, periodic reconciliation signals, path containment,
owner cancellation, quotas and shutdown.

The build manifest links `ioevents.Component()` into the native component list.
Lua entries must declare `ioevents` in `modules`. A process also needs `fs.get`
and `ioevents.watch` grants for the named filesystem resource. An application
receives both, with the module admission, through an approved
`workspace.files.watch` capability, whose read-only volume identity
`bee.gov.binding:granted_resources` reports under `volumes[<subpath>]`.

Consumer example:

```lua
local ioevents = require("ioevents")
local watch, err = ioevents.watch(volume_id, ".")
if not watch then
    error(err)
end
local events = watch:channel()
-- Use the standard Wippy channel receive/select operations.
-- watch:close() cancels the source; process exit also owns cleanup.
```

Watches target one directory under an admitted host filesystem. Files, escaped
paths and unsupported virtual providers are rejected. Watches are not recursive:
subscribe to each directory of interest, and to a file's containing directory to
observe atomic saves. This provider uses host filesystem paths; native code and
the OS account remain outside Lua permission isolation, as with Bee's native
Terminal.

Events have `kind`, `resource`, `path` and `operation` fields. `kind` is `change`
or `rescan`; paths are relative to the filesystem root. Operations normalize to
`create`, `write`, `rename`, `remove` or `other`. The first event requests a rescan,
then another rescan is emitted every five seconds. Consumers must reconcile with
the filesystem: the backend can coalesce or silently drop native notifications.

Each process may own at most 32 watches and the host at most 128. The backend
channel holds 128 events. Runtime message retention is limited to 128 items or
1 MiB per watch; exceeding it closes the channel with an error and stops the
producer. Reopen the watch and rescan to recover. `watch:close()` is idempotent;
native cleanup completes asynchronously. Runtime subscription epochs and
generations prevent events from an old subscription entering a recycled process.
Lua values are constructed on the scheduler step.

Linux amd64 is the tested target. The backend supports macOS and Windows.
Docker Desktop bind mounts can delay or lose native notifications; rescan
handling remains necessary.
