# I/O events

This Bee-owned native component adds `ioevents` to Wippy. It uses the MIT-licensed
Syncthing notify backend, pinned in the parent Go module. The Go service tests
cover real file notifications, periodic reconciliation signals, path containment,
owner cancellation, quotas and shutdown. Lua integration acceptance covers typed lint, denied permissions and real scheduler delivery.

The host links `ioevents.Component()` into its native component list. Lua entries
must declare `ioevents` in `modules`. A process also needs explicit host-selected
`fs.get` and `ioevents.watch` grants for the named filesystem resource. Registry
metadata and module import declarations do not authorize filesystem access.

Callers select a registered filesystem resource and a path relative to its root.
A future `filesystem:watch()` method requires a runtime provider and
authorization contract. See the
[native authoring SDK](https://github.com/wippyai/builder/blob/main/docs/SDK.md)
for the boot path and the current revision-coupled scheduler APIs.

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
Consumers must tolerate lost and coalesced changes.

Each process may own at most 32 watches and the host at most 128. The backend
channel holds 128 events. Runtime message retention is limited to 128 items or
1 MiB per watch; exceeding it closes the channel with an error and stops the
producer. Reopen the watch and rescan to recover. `watch:close()` is idempotent;
native cleanup completes asynchronously. Runtime subscription epochs and
generations prevent events from an old subscription entering a recycled process.
Lua values are constructed on the scheduler step.

Linux amd64 is the tested target. Local Linux Docker acceptance also verifies
host-originated bind-mount changes and permission denial, with networking disabled,
all capabilities dropped and a non-root user. The backend supports macOS and
Windows; Bee acceptance for those platforms is pending. Docker Desktop bind mounts
can delay or lose native notifications; rescan handling remains necessary.

Run `make native-check` after `make native-tools` for race tests, Go vet and Lua integration acceptance. Bee code is MIT;
Wippy and its dependencies retain their upstream licenses. The backend's license
is retained in `native/licenses/notify.txt`.
