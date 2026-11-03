# I/O events

This Bee-owned native component adds `ioevents` to Wippy. It uses the
BSD-licensed fsnotify backend, pinned in the parent Go module. The Go tests
cover real file notifications, recursive watches, overflow rescans, delivery
when the consumer falls behind, path containment, owner cancellation, quotas
and shutdown.

The build manifest links `ioevents.Component()` into the native component list.
Lua entries must declare `ioevents` in `modules`. A process needs only the
`ioevents.watch` grant for the named filesystem resource: a watch reports names
and operations and never hands the caller the filesystem. A host-backed
resource is watched directly. A read-only volume withholds its host directory;
the one host-backed `fs.directory` entry whose `meta.watch_for` names that
volume serves its watches, and the caller never acquires it.

An application receives this through an approved `workspace.files.watch`
capability. The application gets one name for the folder,
`launch.resources.volumes[<subpath>]` from `client.launch` (`bee.app:client`;
functions read the same map from `bee.gov.binding:granted_resources`): it reads the folder with `fs.get`,
read-only, and watches it with `ioevents.watch`. The host-backed watch source
behind it admits no filesystem operation.

```lua
local function main(value)
    local launch = assert(client.launch(value))
    local folder = launch.resources.volumes["docs"]
    local files, err = fs.get(folder)
    if not files then return nil, err end
    local watch
    watch, err = ioevents.watch(folder, ".", {recursive = true})
    if not watch then return nil, err end
    local inbox = process.inbox()
    while true do
        local selected = channel.select({watch:channel():case_receive(), inbox:case_receive()})
        if selected.channel == inbox then
            if selected.value:topic() == "stop" then break end
        elseif not selected.ok then
            watch, err = ioevents.watch(folder, ".", {recursive = true})
            if not watch then return nil, err end
        elseif selected.value.kind == "rescan" then
            local entries, list_err = files:readdir("/" .. selected.value.path)
            if entries then
                for entry in entries do
                    -- reconcile entry.name under selected.value.path
                end
            elseif list_err:kind() ~= errors.NOT_FOUND then
                return nil, list_err
            end
        else
            -- selected.value.operation happened to selected.value.path
        end
    end
    watch:close()
end
```

`ioevents.watch(resource, path, options)` watches one directory, `path`
relative to the resource (default `.`). With `{recursive = true}` it follows
every directory below it, including directories created or moved in later;
symbolic links are never followed. Containment is resolved when the watch
starts and when a directory is followed; a path component replaced by an
outside symlink between that check and the native install is watched where it
points. Failures return `nil, err` with a kind: `Invalid` for a bad path, a
bad option or a file, `PermissionDenied` for a symlink escape or an unreadable
directory, `NotFound`, `RateLimited` at a quota and `Unavailable` after
shutdown or when the native backend cannot start. Messages name only paths
relative to the resource. This provider uses host filesystem paths; native
code and the OS account remain outside Lua permission isolation, as with Bee's
native Terminal.

Events have `kind`, `resource`, `path` and, for a change, `operation`. Paths are
relative to the resource. Operations normalize to `create`, `write`, `rename`,
`remove` or `other`. A `rescan` names a directory whose notices may be missing;
the consumer lists it again. Rescans arrive only then:

- first on every watch, after its native watches are installed;
- on every watch when the backend reports an overflow (the kernel queue on
  Linux, the change buffer on Windows);
- for a directory a recursive watch starts following, which may have gained
  entries before its native watch existed;
- in the channel's last free slot when the consumer is 127 events behind. The
  runtime drops a routed event that finds the channel full, so later notices are
  dropped until the consumer has received that rescan, whose listing covers them.

The channel closes when the watch ends: `watch:close()`, process exit, the
watched directory removed or renamed, a recursive watch outgrowing its quota,
a native failure, or more than 128 notices or 1 MiB waiting in the process
mailbox. Opening the watch again starts with a rescan, or returns the error
that now prevents it. `watch:close()` is idempotent; native cleanup completes
asynchronously. Runtime subscription epochs and generations keep events of an
old subscription out of a recycled process. Lua values are constructed on the
scheduler step.

Each process may own at most 32 watches and the host at most 128. One
recursive watch follows at most 1024 directories, and all watches together at
most 8192; directories several watches follow share one native watch.

Linux amd64 is the tested target. The backend supports macOS (kqueue, which
opens each file of a watched directory) and Windows. Docker Desktop bind mounts
can delay or lose native notifications without an overflow signal.
