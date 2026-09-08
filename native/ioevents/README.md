# I/O events

This Bee-owned native component adds `ioevents` to Wippy. It uses the MIT-licensed
Syncthing notify backend, pinned in the parent Go module. The Go service tests
cover real file notifications, periodic reconciliation signals, path containment,
owner cancellation, quotas and shutdown. Lua integration acceptance covers typed lint, denied permissions and real scheduler delivery.

The host links `ioevents.Component()` into its native component list. Lua entries
must declare `ioevents` in `modules`. A process also needs explicit host-selected
`fs.get` and `ioevents.watch` grants for the named filesystem resource. Registry
metadata and module import declarations do not authorize filesystem access.

Consumer example:

```lua
local ioevents = require("ioevents")
local watch, err = ioevents.watch("workspace:files", ".")
if not watch then
    error(err)
end
local events = watch:channel()
-- Use the standard Wippy channel receive/select operations.
-- watch:close() cancels the source; process exit also owns cleanup.
```

Watches target one directory under an admitted host filesystem. Files, escaped
paths and unsupported virtual providers are rejected. Recursive watching is not
implemented. Subscribe to a file's containing directory to observe atomic saves.
This provider uses host filesystem paths; native code and the OS account remain
outside Lua permission isolation, as with Bee's native Terminal.

Events have `kind`, `resource`, `path` and `operation` fields. `kind` is `change`
or `rescan`; paths are relative to the filesystem root. Operations normalize to
`create`, `write`, `rename`, `remove` or `other`. The first event requests a rescan,
then another rescan is emitted every five seconds. Consumers must reconcile with
the filesystem: the backend can coalesce or silently drop native notifications.
A watch is not a durable event log or evidence that every change was observed.

Each process may own at most 32 watches and the host at most 128. Native event
buffers and routed message retention are bounded. Runtime subscription epochs and
generations prevent events from an old subscription entering a recycled process.
Lua values are constructed on the scheduler step, never on watcher goroutines.

Run `make native-check` after `make native-tools` for race tests, Go vet and Lua integration acceptance. Bee code is MIT;
Wippy and its dependencies retain their upstream licenses. The backend's license
is retained in `native/licenses/notify.txt`.
