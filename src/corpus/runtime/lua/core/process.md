# "Process Management"

_Path: en/lua/core/process_

> "Spawn, monitor, and communicate with child processes. Implements actor-model patterns with message passing, supervision, and lifecycle management."

## Table of Contents

- Process Management

## Content

# Process Management

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>
<secondary-label ref="permissions"/>

The `process` global provides process spawning, messaging, monitoring, linking, naming, and lifecycle control.

It is available without `require()` and does not need to be listed in `modules:`.

This is an API reference. Its call-form blocks use placeholders such as `id`, `host`, `destination`, `topic`, and `name` for values supplied by application code; they are not standalone programs. Calls shown with an `err` result return their documented value on success or a failure sentinel plus `error`; the sentinel is normally `nil`, while `process.set_options` returns `false`. Application control flow should handle the error.



## Process Information


Read the current frame ID or process ID:

```lua
local frame_id, err = process.id()  -- Registry ID of the current function, process, or workflow definition
if err then return nil, err end

local pid, err = process.pid()      -- Process ID
if err then return nil, err end
```



## Sending Messages


Send one or more payload values to a process by PID or registered name:

```lua
local ok, err = process.send(destination, topic, ...)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `destination` | string | PID or registered name |
| `topic` | string | Topic name (cannot start with `@`) |
| `...` | any | Payload values |

**Permission:** `process.send` on target PID



## Spawning Processes


```lua
-- Basic spawn
local pid, err = process.spawn(id, host, ...)

-- With monitoring (receive EXIT events)
local pid, err = process.spawn_monitored(id, host, ...)

-- With linking (receive LINK_DOWN on abnormal exit)
local pid, err = process.spawn_linked(id, host, ...)

-- Both linked and monitored
local pid, err = process.spawn_linked_monitored(id, host, ...)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Process source ID (e.g., `"app.workers:handler"`) |
| `host` | string | Host ID (e.g., `"app:processes"`) |
| `...` | any | Arguments passed to spawned process |

All variants require `process.spawn` on the process ID. The monitored variants also require `process.spawn.monitored`, and the linked variants require `process.spawn.linked`. At runtime v0.3.32a, only the module-level `spawn()` checks `process.host` on the host ID; the specialized module-level variants do not perform that host permission check.



## Process Control


```lua
-- Forcefully terminate a process
local ok, err = process.terminate(destination)

-- Request graceful cancellation with an optional reason
local ok, err = process.cancel(destination, "shutting down")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `destination` | string | PID or registered name |
| `reason` | string | Optional reason delivered to the target |

**Permissions:** `process.terminate`, `process.cancel` on target PID



## Monitoring and Linking


Add or remove monitoring and links for an existing process:

```lua
-- Monitoring: receive EXIT events when target exits
local ok, err = process.monitor(destination)
local ok, err = process.unmonitor(destination)

-- Linking: bidirectional, receive LINK_DOWN on abnormal exit
local ok, err = process.link(destination)
local ok, err = process.unlink(destination)
```

**Permissions:** `process.monitor`, `process.unmonitor`, `process.link`, `process.unlink` on target PID



## Process Options


```lua
local options = process.get_options()
local ok, err = process.set_options({trap_links = true})
```

| Field | Type | Description |
|-------|------|-------------|
| `trap_links` | boolean | Whether LINK_DOWN events are delivered to events channel |
| `upgradable` | boolean | Opt in to OUTDATED events when the process's code is invalidated |



## Inbox and Events


Use the inbox and event channels to receive messages and lifecycle events:

```lua
local inbox = process.inbox()    -- Message objects from @inbox topic
local events = process.events()  -- Lifecycle events from @events topic
```



### Event Types


| Constant | Description |
|----------|-------------|
| `process.event.CANCEL` | Cancellation requested |
| `process.event.EXIT` | Monitored process exited |
| `process.event.LINK_DOWN` | Linked process terminated abnormally |
| `process.event.OUTDATED` | The process's code or an imported dependency changed in the registry |



### Event Fields


| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Event type constant |
| `from` | string | Source PID (absent for OUTDATED) |
| `result` | table | For EXIT/LINK_DOWN: a {value, error} record; the process return value is at `result.value` and any error at `result.error` |
| `reason` | string | For CANCEL: why the process is being cancelled |
| `sources` | string[] | For OUTDATED: registry IDs that changed or were transitively affected |

`OUTDATED` is delivered only to processes that opt in with `process.set_options({upgradable = true})`. Multiple invalidations are combined into one pending event containing the union of their `sources`. Handle the event by calling [`process.upgrade`](#process-upgrade).



## Topic Subscription


Subscribe to a custom message topic:

```lua
local ch, err = process.listen(topic, options)
if err then return nil, err end

local ok, err = process.unlisten(ch)
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `topic` | string | Topic name (cannot start with `@`) |
| `options.message` | boolean | If true, receive Message objects; if false, raw payloads |



## Message Objects


The inbox and listeners configured with `{message = true}` return message objects:

```lua
local msg = inbox:receive()

msg:topic()            -- string: topic name
msg:from()             -- string: sender PID (empty string when unknown)
msg:payload()          -- Payload: wrapper (call :data() to extract); nil when empty, table of wrappers for several values
msg:payload():data()   -- any: actual payload value
```



## Synchronous Call


`process.exec` spawns a process and waits for its result:

```lua
local result, err = process.exec(id, host, ...)
```

**Permissions:** `process.exec` on process id, `process.host` on host id



## Process Upgrade


Upgrade the current process while preserving its PID:

The two snippets below are alternative call forms, not sequential operations.

```lua
-- Upgrade to new version, passing state
process.upgrade(id, ...)
```

```lua
-- Keep same definition, re-run with new state
process.upgrade(nil, preserved_state)
```

`process.upgrade` is a terminal control transfer: it clears the current execution and starts the requested definition with the same PID. Code after the call does not run in the old execution.



## Context Spawner


Create a spawner that supplies custom context to child processes:

```lua
local spawner = process.with_context({request_id = "123"})
```

**Permission:** `process.context` on "context"



### Spawner with Options


`process.with_options(options)` creates a spawner with spawn-time options, such as a network selector, rather than context values:

```lua
local spawner = process.with_options({network = "app:tor_proxy"})
```

| Option | Type | Description |
|--------|------|-------------|
| `network` | string | Registry ID of a `network.*` entry to use for the child's outbound connections |
| `terminal` | string | Viewport grant that attaches a virtual terminal to the child |

**Permission:** `process.context` on "context"; selecting a network additionally requires `network.select` on that network ID.



### Terminal Attachment


A `terminal` grant comes from `viewport:grant()` and gives the child a terminal port of its own, so it can use the [TTY](lua/system/tty.md) module exactly as it would on a terminal host:

```lua
local view = assert(tty.viewport({width = 80, height = 24}))
local child = assert(process.with_options({terminal = assert(view:grant())})
    :spawn_monitored("app:child", "app:workers"))
```

The grant is one-shot and is consumed at admission: a rejected start leaves it unresolved and reusable, a child that resolves the port consumes it permanently, and a host that does not support terminal attachments rejects the spawn rather than dropping the option. The spawning process keeps reading the child's frames through the viewport it created. See [Terminal](system/terminal.md#composable-terminals).



### SpawnBuilder Methods


`SpawnBuilder` is immutable; each configuration method returns a new instance:

```lua
spawner:with_context(values)      -- Add context values
spawner:with_actor(actor)         -- Set security actor
spawner:with_scope(scope)         -- Set security scope
spawner:with_name(name)           -- Register name at start; if taken, spawn returns the existing PID and queued messages go to it
spawner:with_message(topic, ...)  -- Queue message to send after spawn
spawner:with_options(options)     -- Merge spawn-time options (e.g. network)
```

**Permission:** `process.security` on "security" for `:with_actor()` and `:with_scope()`



### Spawner Spawn Methods


```lua
spawner:spawn(id, host, ...)
spawner:spawn_monitored(id, host, ...)
spawner:spawn_linked(id, host, ...)
spawner:spawn_linked_monitored(id, host, ...)
```

All `SpawnBuilder` spawn methods require `process.host` on the host ID in addition to the applicable `process.spawn`, `process.spawn.monitored`, and `process.spawn.linked` permissions.



### Spawner Exec


```lua
local result, err = spawner:exec(id, host, ...)
```

This method runs the target process synchronously with the builder's context, actor, and scope, then returns its result. A deferred worker can use `with_actor` and `with_scope` to execute with an owner's identity.

**Permissions:** `process.exec` on process id, `process.host` on host id



## Name Registry


Register a process under a name so callers can use the name instead of its PID. Functions that accept a `destination`, including `send`, `terminate`, `cancel`, `monitor`, and `link`, also accept registered names.

```lua
local ok, err = process.registry.register(name)               -- self, local scope
local pid, err = process.registry.lookup(name)
local ok, err = process.registry.unregister(name)
```



### Scope


The optional `scope` argument selects the name's consistency guarantee and defaults to `LOCAL`. See the [Cluster Guide](guides/cluster.md#naming-and-name-scopes) for the complete model.

| Constant | Visibility | Guarantee |
|----------|------------|-----------|
| `process.registry.LOCAL` | this node only | Instant, node-local |
| `process.registry.EVENTUAL` | cluster-wide | Eventually consistent (gossip) |
| `process.registry.CONSISTENT` | cluster-wide | Linearizable singleton (Raft) |
| `process.registry.STRONG` | cluster-wide | Consistent + every live node acknowledges |

On a standalone node, only `LOCAL` is available; cluster scopes require [clustering](guides/cluster.md).



### register


```lua
local ok, err = process.registry.register(name, pid, scope)
```

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `name` | string | yes | | Name to register |
| `pid` | string | no | self | PID to register; defaults to the calling process |
| `scope` | number | no | `LOCAL` | One of the scope constants above |

Returns `true` on success, or `nil, error` on failure. Conflicts (name already registered to a different PID) return `errors.ALREADY_EXISTS`. Registering the same name to the same PID is idempotent. A `STRONG` registration blocks until every live node acknowledges or the reservation deadline expires; on timeout it returns an error.

Registering on behalf of a different PID additionally requires the `process.registry.foreign` permission on the target PID.



### lookup


```lua
local pid, err = process.registry.lookup(name)
```

Returns the registered PID string, or `nil, error` with kind `errors.NOT_FOUND` when the name is not registered.



### unregister


```lua
local ok, err = process.registry.unregister(name, scope)
```

`scope` defaults to `LOCAL` and must match the scope the name was registered under. For `CONSISTENT` and `STRONG`, the owning process is the one allowed to unregister; unregistering a name owned by another PID returns `false`. Names also release automatically when the owning process exits (and, for cluster scopes, when its node leaves), so explicit unregister is for early release.



## Permissions


Permission checks evaluate the caller's security actor against the target resource.



### Policy Evaluation


Policies can allow or deny an operation based on:

- **Actor**: The security principal making the request
- **Action**: The operation being performed (e.g., `process.send`)
- **Resource**: The target (PID, process id, host id, or name)
- **Attributes**: Additional context including `pid` (caller's process ID)



### Permission Reference


| Permission | Functions | Resource |
|------------|-----------|----------|
| `process.spawn` | `spawn*()` | process id |
| `process.spawn.monitored` | `spawn_monitored()`, `spawn_linked_monitored()` | process id |
| `process.spawn.linked` | `spawn_linked()`, `spawn_linked_monitored()` | process id |
| `process.host` | module-level `spawn()`, all `SpawnBuilder` spawn methods, `exec()` | host id |
| `process.send` | `send()` | target PID |
| `process.exec` | `exec()` | process id |
| `process.terminate` | `terminate()` | target PID |
| `process.cancel` | `cancel()` | target PID |
| `process.monitor` | `monitor()` | target PID |
| `process.unmonitor` | `unmonitor()` | target PID |
| `process.link` | `link()` | target PID |
| `process.unlink` | `unlink()` | target PID |
| `process.context` | `with_context()`, `with_options()` | "context" |
| `process.security` | `:with_actor()`, `:with_scope()` | "security" |
| `process.registry.register` | `registry.register()` | name |
| `process.registry.unregister` | `registry.unregister()` | name |
| `process.registry.foreign` | `registry.register()` | target PID |

Cluster name scopes are authorized by scope-suffixed variants of these actions (`process.registry.register.eventual`, `.consistent`, `.strong`, and the matching `unregister` actions), so a policy can grant local naming separately from cluster-wide naming.



### Multiple Permissions


Some operations require multiple permissions:

| Operation | Required Permissions |
|-----------|---------------------|
| `spawn()` | `process.spawn` + `process.host` |
| module-level `spawn_monitored()` | `process.spawn` + `process.spawn.monitored` |
| module-level `spawn_linked()` | `process.spawn` + `process.spawn.linked` |
| module-level `spawn_linked_monitored()` | `process.spawn` + `process.spawn.monitored` + `process.spawn.linked` |
| `SpawnBuilder:spawn()` | `process.spawn` + `process.host` |
| `SpawnBuilder:spawn_monitored()` | `process.spawn` + `process.spawn.monitored` + `process.host` |
| `SpawnBuilder:spawn_linked()` | `process.spawn` + `process.spawn.linked` + `process.host` |
| `SpawnBuilder:spawn_linked_monitored()` | `process.spawn` + `process.spawn.monitored` + `process.spawn.linked` + `process.host` |
| `exec()` | `process.exec` + `process.host` |
| spawn with custom actor/scope | spawn permissions + `process.security` |



## Errors


| Condition | Kind |
|-----------|------|
| No context found | `errors.INTERNAL` |
| Frame context not found | `errors.INTERNAL` |
| Missing required arguments | `errors.INVALID` |
| Reserved topic prefix (`@`) | `errors.INVALID` |
| Destination is neither a PID nor a registered name | `errors.NOT_FOUND` |
| Name not registered | `errors.NOT_FOUND` |
| Permission denied | `errors.PERMISSION_DENIED` |
| Name already registered | `errors.ALREADY_EXISTS` |

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Channels](lua/core/channel.md) - In-process coroutine coordination
- [Message Queue](lua/storage/queue.md) - Queue-based messaging
- [Functions](lua/core/funcs.md) - Function invocation
- [Supervision](guides/supervision.md) - Process lifecycle management
- [Cluster](guides/cluster.md) - Name scopes and cluster-wide naming



## Navigation

Previous: "Channels and Coroutines" (lua/core/channel)
Next: "Process Groups" (lua/core/pg)
