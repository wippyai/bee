# "Process Groups"

_Path: en/lua/core/pg_

> "Join processes into named groups and broadcast to every member across the cluster. Modeled on Erlang/OTP pg: groups are dynamic, a process can belong…"

## Table of Contents

- Process Groups

## Content

# Process Groups

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="permissions"/>

Process groups organize processes under dynamic names and broadcast messages to group members across the cluster. A process can join multiple groups, and cluster-wide membership is eventually consistent.

This is an API reference. Its snippets assume an existing `pg.scope`, an executable entry running with process context, and policies that authorize the documented operations. The blocks demonstrate individual calls or partial subscription flows rather than a standalone application.

For the scope entry kind and its configuration, see [Process Groups](system/process-groups.md). For the broader clustering model, see the [Cluster Guide](guides/cluster.md).



## Loading


```lua
local pg = require("pg")
```

Add `pg` to the executable entry's `modules:` list before requiring it.



## Opening a Scope


A process group belongs to a **scope**, represented by a `pg.scope` registry entry. Open the scope to obtain an instance for group operations:

```lua
local group, err = pg.open("app:pg")
if err then
    return nil, err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Scope entry ID (format: `"namespace:name"`) |

**Returns:** `pg.Instance, error`

**Permission:** `pg.open` on the scope `id`

The instance is released automatically during execution-frame cleanup. Call `release()` to release it earlier. Other operations are methods on the instance and use `:` syntax.



## Joining and Leaving


The calls below are independent forms; choose the single-group or batch join needed by the application and pair it with the corresponding leave operations.

```lua
local ok, err = group:join("workers")           -- single group
if err then return nil, err end
```

```lua
local ok, err = group:join({"workers", "all"})  -- batch
if err then return nil, err end
```

```lua
local ok, err = group:leave("workers")
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `group` | string \| string[] | Group name, or a list of names for a batch operation |

**Returns:** `boolean, error`

A process can join the same group more than once and must leave the same number of times to depart fully. For a batch, `leave` is best-effort and returns an error only when the process was not a member of any named group.

**Permissions:** `pg.join` / `pg.leave` on each group name



## Listing Members


```lua
local members, err = group:get_members("workers")        -- all nodes
if err then return nil, err end

local local_members, err = group:get_local_members("workers")  -- this node only
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `group` | string | Group name |

**Returns:** `string[], error` — an array of PID strings (empty for an unknown group)

**Permissions:** `pg.get_members` / `pg.get_local_members` on the group name



## Listing Groups


```lua
local groups, err = group:which_groups()         -- all groups in the cluster
if err then return nil, err end

local local_groups, err = group:which_local_groups()  -- groups with a local member
if err then return nil, err end
```

**Returns:** `string[], error` — group names that currently have at least one member

**Permissions:** `pg.which_groups` / `pg.which_local_groups`



## Broadcasting


Broadcast sends a message from the calling process to every group member under `topic`. Members receive it with `process.listen(topic)`.

```lua
local ok, err = group:broadcast("workers", "task", {id = 42})   -- all nodes
if err then return nil, err end

ok, err = group:broadcast_local("workers", "task", {id = 42})  -- this node only
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `group` | string | Target group |
| `topic` | string | Message topic |
| `...` | any | Zero or more payload values |

**Returns:** `boolean, error`

**Permissions:** `pg.broadcast` / `pg.broadcast_local` on the group name



## Monitoring a Group


`monitor` subscribes to join and leave events for one group and returns an atomic snapshot of its current members. No membership change can occur between the snapshot and subscription setup without being observed.

```lua
local sub, members, err = group:monitor("workers")
if err then
    return nil, err
end

for _, pid in ipairs(members) do
    -- current members at subscription time
end

local ch = sub:channel()
local event, open = ch:receive()  -- {kind = "member.joined" | "member.left", path = "workers", data = {...}}
if not open then
    return nil, errors.new("Process-group subscription closed")
end

sub:close()  -- unsubscribe; sub:close({flush = true}) drains queued events first
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `group` | string | Group to watch |

**Returns:** `pg.Subscription, string[], error` — the subscription and a snapshot of current members

**Permission:** `pg.monitor` on the group name



## Watching All Groups


`events` subscribes to membership changes for every group in the scope and returns a snapshot mapping groups to their members.

```lua
local sub, snapshot, err = group:events()
if err then
    return nil, err
end
-- snapshot: { ["workers"] = {pid, ...}, ["all"] = {pid, ...} }

local event, open = sub:channel():receive()
if not open then
    return nil, errors.new("Process-group subscription closed")
end
sub:close()
```

**Returns:** `pg.Subscription, table, error`

**Permission:** `pg.events`



### Event Fields


Events delivered on a subscription channel carry:

| Field | Type | Description |
|-------|------|-------------|
| `system` | string | Always `"pg"` |
| `kind` | string | `"member.joined"` or `"member.left"` |
| `path` | string | The group name |
| `data` | table | `{Group = string, PIDs = string[]}` — the affected members |

Subscription channels are buffered (capacity 64). If a slow consumer fills the buffer, further events are retained in the process mailbox in order and delivered once the consumer drains the channel (the subscription stalls rather than dropping events).



## Releasing


```lua
group:release()
```

`release` frees the instance immediately and is idempotent. After release, every other group operation returns an error. Cleanup also runs automatically at the end of the execution frame.

**Returns:** `boolean`



## Permissions


| Permission | Method | Resource |
|------------|--------|----------|
| `pg.open` | `pg.open()` | scope id |
| `pg.join` | `join()` | group name |
| `pg.leave` | `leave()` | group name |
| `pg.get_members` | `get_members()` | group name |
| `pg.get_local_members` | `get_local_members()` | group name |
| `pg.which_groups` | `which_groups()` | (none) |
| `pg.which_local_groups` | `which_local_groups()` | (none) |
| `pg.broadcast` | `broadcast()` | group name |
| `pg.broadcast_local` | `broadcast_local()` | group name |
| `pg.monitor` | `monitor()` | group name |
| `pg.events` | `events()` | (none) |



## Errors


| Condition | Kind |
|-----------|------|
| Permission denied | `errors.PERMISSION_DENIED` |
| Missing or empty argument | `errors.INVALID` |
| Scope not found | `errors.INTERNAL` |
| Leave a group with no membership | `errors.NOT_FOUND` |
| Instance released | `errors.INVALID` |
| Group/member or action-queue limit reached | `errors.RATE_LIMITED` (retryable) |
| Service stopped, backpressure, or open circuit | `errors.UNAVAILABLE` |
| Broadcast timed out | `errors.TIMEOUT` (retryable) |

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Process Groups](system/process-groups.md) - Scope entry kind and configuration
- [Cluster](guides/cluster.md) - Membership, naming, and the clustering model
- [Process Management](lua/core/process.md) - Spawning and messaging individual processes



## Navigation

Previous: "Process Management" (lua/core/process)
Next: "Function Invocation" (lua/core/funcs)
