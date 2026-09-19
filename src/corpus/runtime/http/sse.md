# "Server-Sent Events"

_Path: en/http/sse_

> "Stream short-lived handler events or long-lived process-backed events over Server-Sent Events."

## Table of Contents

- Server-Sent Events

## Content

# Server-Sent Events


The SSE middleware streams events from the server to HTTP clients using the [Server-Sent Events](https://html.spec.whatwg.org/multipage/server-sent-events.html) protocol.

Two mechanisms are available: **direct streaming** from an HTTP handler, and **process-backed relay** via the `sse_relay` middleware.

**Classification: protocol reference with partial integration recipes.** The
relay blocks assume an HTTP server, router, process host, target process, and
security context already exist. Application callbacks and client behavior are
outside these snippets.



## Direct Streaming


Use `res:write_event()` to send SSE events directly from an HTTP handler. The response automatically switches to SSE mode on the first call, setting appropriate headers.

```lua
local http = require("http")

local function handler()
    local res, res_err = http.response()
    if res_err then return nil, res_err end

    local err = res:write_event({name = "status", data = {state = "started"}})
    if err then return nil, err end
    err = res:write_event({name = "progress", data = {percent = 50}})
    if err then return nil, err end
    err = res:write_event({name = "status", data = {state = "complete"}})
    if err then return nil, err end
    return true
end
```

Each event requires a `name` and `data` field. The `data` value is JSON-encoded automatically.

<tip>
Direct streaming is suitable for short-lived request-response flows like progress updates. For long-lived connections managed by background processes, use the SSE Relay.
</tip>



## SSE Relay


The SSE Relay middleware creates long-lived SSE streams backed by processes. It follows the same relay pattern as [WebSocket Relay](http/websocket-relay.md).



### How It Works


1. HTTP handler sets `X-SSE-Relay` header with a JSON relay configuration
2. Middleware intercepts the response and creates an SSE session
3. Session registers as a process with its own PID
4. Messages sent to the session PID are forwarded as SSE events to the client



## Process Semantics


SSE streams are full processes with their own PID. They integrate with the process system:

- **Addressable** — Any process can send messages to a stream PID
- **Monitorable** — Processes can monitor SSE streams for exit events
- **Linkable** — SSE streams can be linked to other processes
- **EXIT events** — When a stream closes, monitors receive exit notifications

```lua
-- Send event to SSE client from any process
local _, send_err = process.send(stream_pid, "sse.message", {event = "update", value = 42})
if send_err then return nil, send_err end

-- Monitor an SSE stream
local _, monitor_err = process.monitor(stream_pid)
if monitor_err then return nil, monitor_err end
```

<tip>
The relay monitors the target process. If the target exits, the SSE stream closes automatically and the client receives a `done` event.
</tip>



## Configuration


Add as post-match middleware on a router:

```yaml
- name: sse_router
  kind: http.router
  meta:
    server: gateway
  prefix: /sse
  post_middleware:
    - sse_relay
  post_options:
    sserelay.allowed.origins: "https://app.example.com"
```

| Option | Description |
|--------|-------------|
| `sserelay.allowed.origins` | Comma-separated allowed origins (supports wildcards) |

<note>
If no origins are configured, only same-origin requests are allowed.
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
    local pid, spawn_err = process.spawn("app.sse:handler", "app:processes")
    if spawn_err then return nil, spawn_err end

    -- Configure relay
    local relay_config, encode_err = json.encode({
        target_pid = tostring(pid),
        message_topic = "sse.message",
        heartbeat_interval = "30s",
        metadata = {
            user_id = user_id
        }
    })
    if encode_err then
        local _, terminate_err = process.terminate(pid)
        return nil, terminate_err or encode_err
    end

    local header_err = res:set_header("X-SSE-Relay", relay_config)
    if header_err then
        local _, terminate_err = process.terminate(pid)
        return nil, terminate_err or header_err
    end
end
```



### Relay Config Fields


| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `target_pid` | string | — | Process PID to receive messages (omit for detached mode) |
| `message_topic` | string | `sse.message` | Topic filter for forwarded events |
| `heartbeat_interval` | duration | `30s` | Heartbeat frequency (e.g. `30s`, `1m`) |
| `idle_timeout` | duration | — | Close stream after inactivity |
| `hard_timeout` | duration | — | Close stream after absolute duration |
| `metadata` | object | — | Attached to join/leave/heartbeat messages |



### Managed Mode


When `target_pid` is set, the relay operates in managed mode:

- Monitors the target process
- Sends `sse.join` on connect and `sse.leave` on disconnect
- Closes the stream automatically if the target exits



### Detached Mode


When `target_pid` is omitted, the relay starts in detached mode:

- Emits a `ready` event to the client with `stream_pid` and `message_topic`
- No process is monitored initially
- A process can attach later by sending an `sse.control` message

Inside a handler that has imported `json` and obtained the response object as
`res`, set up detached mode and check both operations:

```lua
-- Detached setup: no target_pid
local relay_config, encode_err = json.encode({
    heartbeat_interval = "30s"
})
if encode_err then return nil, encode_err end

local header_err = res:set_header("X-SSE-Relay", relay_config)
if header_err then return nil, header_err end
```

The client receives a `ready` event:

```json
{"stream_pid": "{n1@app:gateway|0x0002a}", "message_topic": "sse.message"}
```



## Message Topics


The relay uses these topics for communication between the stream and target process:

| Topic | Direction | When | Payload |
|-------|-----------|------|---------|
| `sse.join` | stream → target | Client connects | `client_pid`, `metadata` |
| `sse.message` | target → stream | Default event topic | Forwarded as SSE event |
| `sse.heartbeat` | stream → target | Periodic (every 30s by default) | `client_pid`, `uptime`, `message_count`, `metadata` |
| `sse.leave` | stream → target | Client disconnects | `client_pid`, `metadata` |
| `sse.control` | any → stream | Control command | Relay config fields |
| `sse.close` | any → stream | Force close | Optional reason string |



## Receiving in Target Process


```lua
local function handler()
    local inbox = process.inbox()

    while true do
        local msg, ok = inbox:receive()
        if not ok then break end

        local topic = msg:topic()
        local data, payload_err = msg:payload():data()
        if payload_err then return nil, payload_err end

        if topic == "sse.join" then
            local client_pid = data.client_pid

        elseif topic == "sse.heartbeat" then
            -- Periodic health check

        elseif topic == "sse.leave" then
            -- Release application state associated with data.client_pid.
        end
    end
end
```



## Sending Events


Send events to the client by messaging the stream PID:

```lua
-- Send on the default message topic
local _, send_err = process.send(stream_pid, "sse.message", {
    event = "update",
    value = 42
})
if send_err then return nil, send_err end

-- Force close the stream
local _, close_err = process.send(stream_pid, "sse.close", "session expired")
if close_err then return nil, close_err end
```

Events sent on the configured `message_topic` are forwarded to the client as SSE events. The topic name becomes the SSE event name.



## Connection Transfer


Send a control message to change the target process, topic filter, or timeouts dynamically:

```lua
local _, transfer_err = process.send(stream_pid, "sse.control", {
    target_pid = tostring(new_pid),
    message_topic = "custom.topic",
    idle_timeout = "5m"
})
if transfer_err then return nil, transfer_err end
```

When the target changes, the relay first monitors and sends `sse.join` to the new target, then stops monitoring and sends `sse.leave` to the old one. Set `target_pid` to an empty string to detach without reattaching.



## See Also


- [Middleware](http/middleware.md) — Middleware configuration
- [WebSocket Relay](http/websocket-relay.md) — WebSocket equivalent
- [Process](lua/core/process.md) — Process messaging



## Navigation

Previous: "WebSocket Relay" (http/websocket-relay)
Next: "Hello World" (tutorials/hello-world)
