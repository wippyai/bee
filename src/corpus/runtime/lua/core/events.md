# "Event Bus"

_Path: en/lua/core/events_

> "Publish and subscribe to events for observability — monitoring runtime and application activity and reacting to it."

## Table of Contents

- Event Bus

## Content

# Event Bus

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="permissions"/>

The event bus publishes runtime and application activity for monitoring, logging, metrics, and reactive side effects. This page is an API reference; the snippets assume an executable Lua entry with the listed module and permissions.

<note>
The event bus is a best-effort publish/subscribe channel, not a reliable transport. Do not depend on it for business-critical delivery. Use process messaging (`process.send`), channels, or the [message queue](lua/storage/queue.md) when delivery is part of application correctness.
</note>



## Loading


```lua
local events = require("events")
```



## Subscribing to Events


Subscribe to one system or a system pattern, with an optional event-kind filter:

```lua
-- Subscribe to all order events
local sub, err = events.subscribe("orders.*")
if err then
    return nil, err
end

-- Process events
local ch = sub:channel()
while true do
    local evt, ok = ch:receive()
    if not ok then break end

    print(evt.system, evt.kind, evt.path)
    -- Process evt.data when the publisher supplied a payload.
end
```

Pass a second argument to restrict delivery to one kind, for example
`events.subscribe("users", "user.created")`. An omitted kind accepts every
kind from the matching system.

| Parameter | Type | Description |
|-----------|------|-------------|
| `system` | string | System pattern (supports wildcards like "test.*") |
| `kind` | string | Event kind filter (optional) |

**Returns:** `Subscription, error`



## Publishing Events


Publish an event to the event bus:

```lua
-- Send order created event
local ok, err = events.send("orders", "order.created", "/orders/123", {
    order_id = "123",
    customer_id = "456",
    total = 99.99
})
if err then
    return nil, err
end

-- Send without data
local heartbeat_sent, heartbeat_err = events.send("system", "heartbeat", "/health")
if heartbeat_err then
    return nil, heartbeat_err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `system` | string | System identifier |
| `kind` | string | Event kind/type |
| `path` | string | Event path for routing |
| `data` | any | Event payload (optional) |

**Returns:** `boolean, error`

A successful return confirms that the runtime accepted the send. It does not
confirm that any subscriber received or processed the event.



### Receive Channel


Use the subscription channel to receive events:

```lua
local json = require("json")
local ch = sub:channel()

local evt, ok = ch:receive()
if ok then
    print("System:", evt.system)
    print("Kind:", evt.kind)
    print("Path:", evt.path)
    local encoded, encode_err = json.encode(evt.data)
    if encode_err then return nil, encode_err end
    print("Data:", encoded)
end
```

Each event contains `system`, `kind`, and `path`. The `data` field is present
only when the publisher supplied a non-nil payload.



### Close a Subscription


Close the subscription to unsubscribe and close its channel:

```lua
local closed = sub:close() -- true
```

Closing is idempotent. After the channel is closed, `receive()` returns
`nil, false` once buffered events are drained.



## Permissions


| Action | Resource | Description |
|--------|----------|-------------|
| `events.subscribe` | system | Subscribe to events from a system |
| `events.send` | system | Send events to a system |



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty system | `errors.INVALID` | no |
| Empty send kind | `errors.INVALID` | no |
| Empty path | `errors.INVALID` | no |
| Policy denied | `errors.INVALID` | no |
| Missing execution or process context | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Request Context" (lua/core/context)
Next: "Entry Registry" (lua/core/registry)
