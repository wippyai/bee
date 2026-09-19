# "WebSocket Relay"

_Path: en/http/websocket-relay_

> "The WebSocket relay middleware upgrades HTTP connections to WebSocket and relays messages to a target process."

## Table of Contents

- WebSocket Relay

## Content

# WebSocket Relay


The `websocket_relay` middleware upgrades an HTTP connection and relays WebSocket messages to a target process.

**Classification: protocol reference with partial integration recipes.** The
blocks assume an HTTP server, router, process host, target process, and security
context. Application message handlers and client-state cleanup remain
application-owned.



## How It Works


1. HTTP handler sets `X-WS-Relay` header with target process PID
2. Middleware upgrades connection to WebSocket
3. Relay attaches to the target process and monitors it
4. Messages flow bidirectionally between client and process



## Process Semantics


WebSocket connections are full processes with their own PID. They integrate with the process system:

- **Addressable** → Any process can send messages to a WebSocket PID
- **Monitorable** → Processes can monitor WebSocket connections for exit events
- **Linkable** → WebSocket connections can be linked to other processes
- **EXIT events** → When connection closes, monitors receive exit notifications

```lua
-- Monitor a WebSocket connection from another process
local _, monitor_err = process.monitor(websocket_pid)
if monitor_err then return nil, monitor_err end

-- Send a message to the WebSocket client from any process.
-- The relay wraps it as {topic, data} JSON; the topic name is arbitrary.
local _, send_err = process.send(websocket_pid, "update", "hello")
if send_err then return nil, send_err end
```

<tip>
The relay monitors the target process. If the target exits, the WebSocket connection closes automatically and the client receives a close frame.
</tip>



## Connection Transfer


Connections can be transferred to a different process by sending a control message:

```lua
local _, transfer_err = process.send(websocket_pid, "ws.control", {
    target_pid = new_process_pid,
    message_topic = "ws.message"
})
if transfer_err then return nil, transfer_err end
```



## Configuration


Add as post-match middleware on a router:

```yaml
- name: ws_router
  kind: http.router
  meta:
    server: gateway
  prefix: /ws
  post_middleware:
    - websocket_relay
  post_options:
    wsrelay.allowed.origins: "https://app.example.com"
```

| Option | Description |
|--------|-------------|
| `wsrelay.allowed.origins` | Comma-separated allowed origins |

<note>
If no origins configured, only same-origin requests are allowed.
</note>



## Handler Setup


The HTTP handler spawns a process and configures the relay:

```lua
local http = require("http")
local json = require("json")

local function handler()
    local req, req_err = http.request()
    if req_err then return nil, req_err end
    local res, res_err = http.response()
    if res_err then return nil, res_err end

    local user_id, query_err = req:query("user_id")
    if query_err then return nil, query_err end

    -- Spawn handler process
    local pid, spawn_err = process.spawn("app.ws:handler", "app:processes")
    if spawn_err then return nil, spawn_err end

    -- Configure relay
    local relay_config, encode_err = json.encode({
        target_pid = tostring(pid),
        message_topic = "ws.message",
        heartbeat_interval = "30s",
        metadata = {
            user_id = user_id
        }
    })
    if encode_err then
        local _, terminate_err = process.terminate(pid)
        return nil, terminate_err or encode_err
    end

    local header_err = res:set_header("X-WS-Relay", relay_config)
    if header_err then
        local _, terminate_err = process.terminate(pid)
        return nil, terminate_err or header_err
    end
end
```



### Relay Config Fields


| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `target_pid` | string | required | Process PID to receive messages |
| `message_topic` | string | `ws.message` | Topic for client messages |
| `heartbeat_interval` | duration | `30s` | Heartbeat frequency (e.g. `30s`) |
| `metadata` | object | - | Attached to join/leave/heartbeat messages |



## Message Topics


The relay sends these messages to the target process:

| Topic | When | Payload |
|-------|------|---------|
| `ws.join` | Client connects | JSON `{client_pid, metadata}` |
| `ws.message` (or your `message_topic`) | Client sends message | Raw client payload (text frame → String format, binary frame → Bytes format); `payload:data()` returns a Lua string for either format, and the source PID is the client PID |
| `ws.heartbeat` | Periodic (every 30s by default; interval overridable via `heartbeat_interval`) | JSON `{client_pid, uptime, message_count, metadata}` |
| `ws.leave` | Client disconnects | JSON `{client_pid, metadata}` |



## Receiving Messages


```lua
local function handler()
    local inbox = process.inbox()

    while true do
        local msg, ok = inbox:receive()
        if not ok then break end

        local topic = msg:topic()
        local from = msg:from()                -- client connection PID

        if topic == "ws.join" then
            -- Client connected — payload is {client_pid, metadata}
            local data, payload_err = msg:payload():data()
            if payload_err then return nil, payload_err end
            local client_pid = data.client_pid

        elseif topic == "ws.message" then
            -- Raw client message; from() is the client PID
            local incoming = msg:payload()
            local frame_format = incoming:get_format()     -- "text/plain" or "application/octet-stream"
            local body, payload_err = incoming:data()      -- Lua string in either case
            if payload_err then return nil, payload_err end
            -- Decode or dispatch `body` according to `frame_format` and the
            -- application's protocol.

        elseif topic == "ws.leave" then
            -- Client disconnected — payload is {client_pid, metadata}
            -- Release application state associated with `from`.
        end
    end
end
```



## Sending to Client


Send messages back using the client PID. Any topic you choose is wrapped as `{topic, data}` JSON and forwarded to the WebSocket. Every server-to-client message is sent as a single WebSocket text frame containing the wrapper. Tables remain JSON objects in `data`; strings remain strings. Payloads that reach the relay in Bytes format are base64-encoded into `data`; they are not sent as separate binary frames. Lua `process.send` exports its arguments as Lua-format payloads, so a Lua string does not take the Bytes-format branch.

```lua
-- Send a structured message (any topic name)
process.send(client_pid, "update", json.encode({event = "update", value = 42}))

-- Close connection (payload is the close reason string)
local _, close_err = process.send(client_pid, "ws.close", "Session ended")
if close_err then return nil, close_err end
```

The reserved topics from server → client are `ws.control` (relay reconfiguration) and `ws.close` (close the connection).



## Broadcasting


Track client PIDs to broadcast to multiple clients:

```lua
local clients = {}

-- On join
clients[client_pid] = true

-- On leave
clients[client_pid] = nil

-- Broadcast
local function broadcast(message)
    for pid, _ in pairs(clients) do
        local _, send_err = process.send(pid, "broadcast", message)
        if send_err then return nil, send_err end
    end
    return true
end
```

<tip>
For complex multi-room scenarios, spawn a separate handler process per room or use a central manager process that tracks room memberships.
</tip>



## See Also


- [Middleware](http/middleware.md) - Middleware configuration
- [Process](lua/core/process.md) - Process messaging
- [WebSocket Client](lua/http/websocket.md) - Outbound WebSocket connections



## Navigation

Previous: "Static Files" (http/static)
Next: "Server-Sent Events" (http/sse)
