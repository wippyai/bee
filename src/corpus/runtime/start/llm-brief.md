# "LLM Brief"

_Path: en/start/llm-brief_

> "Core Wippy concepts, project structure, APIs, and conventions for agents that generate Wippy code."

## Table of Contents

- LLM Brief

## Content

# LLM Brief


Use this brief as the starting context when generating code for a Wippy project.

**Classification: generation reference.** The blocks below are focused contract
patterns, not one runnable project. Registry IDs, schemas, policies, and
application-specific values such as `user_id`, `config`, and `content` must be
defined by the project that uses them.



## What Wippy Is


Wippy is a single-binary application runtime built on the actor model. It runs Lua code in isolated processes that communicate through messages rather than shared memory. Its three compute models are functions (stateless and request-scoped), processes (long-lived actors with state), and workflows (durable actors backed by Temporal). Registry-backed behavior can be added or updated without redeploying the runtime.



## Mental Model


Everything in Wippy is a **registry entry**. An entry has an ID (`namespace:name`), a kind that determines its behavior, metadata, and data. YAML files are one way to declare entries, but the registry is the runtime source of truth. Entries can also be created, updated, or deleted while the system is running.

Kinds determine what an entry does:

- `function.lua` — stateless callable function
- `process.lua` — long-running actor
- `workflow.lua` — durable workflow (Temporal)
- `http.service` — HTTP server
- `http.router` — route group with middleware
- `http.endpoint` — HTTP handler
- `db.sql.postgres` / `mysql` / `sqlite` — database connection
- `store.memory` / `store.sql` — key-value store
- `queue.queue` — message queue
- `process.host` — process execution host
- `process.service` — supervised process
- `contract.definition` / `contract.binding` — typed service interfaces
- `registry.entry` — configuration data



## Project Structure


```
myapp/
├── .wippy.yaml              # Runtime configuration
├── wippy.lock               # Source directories
└── src/
    ├── _index.yaml          # Entry definitions (namespace: app)
    ├── api/
    │   ├── _index.yaml      # namespace: app.api
    │   └── handler.lua
    └── workers/
        ├── _index.yaml      # namespace: app.workers
        └── task.lua
```

Entry definitions live in `_index.yaml` files:

```yaml
version: "1.0"
namespace: app.api

entries:
  - name: get_user
    kind: function.lua
    source: file://handler.lua
    method: get_user
    modules: [sql]

  - name: get_user.endpoint
    kind: http.endpoint
    meta:
      router: app:api_router
    method: GET
    path: /users/{id}
    func: app.api:get_user
```



## Writing Functions


Functions are stateless: they receive arguments, perform work, and return results. They inherit the caller's context and are canceled when the caller is canceled.

```lua
local sql = require("sql")

local function get_user(id)
    local db, err = sql.get("app:main_db")
    if err then return nil, err end

    local rows, err = db:query("SELECT * FROM users WHERE id = $1", {id})
    if err then return nil, err end
    if #rows == 0 then return nil, errors.new({kind = errors.NOT_FOUND, message = "user not found"}) end

    return rows[1]
end

return get_user
```

For HTTP handlers, use the `http` module:

```lua
local http = require("http")
local json = require("json")
local funcs = require("funcs")

local function handler()
    local req, req_err = http.request()
    if req_err then return nil, req_err end
    local res, res_err = http.response()
    if res_err then return nil, res_err end

    local id, param_err = req:param("id")
    if param_err then return nil, param_err end
    local user, err = funcs.call("app.api:get_user", id)
    if err then
        local status_err
        if errors.is(err, errors.NOT_FOUND) then
            status_err = res:set_status(404)
        else
            status_err = res:set_status(500)
        end
        if status_err then return nil, status_err end
        local write_err = res:write_json({error = err:message()})
        if write_err then return nil, write_err end
        return true
    end

    local write_err = res:write_json(user)
    if write_err then return nil, write_err end
    return true
end

return handler
```



## Writing Processes


Processes are actors. Each process has a PID, receives messages through an inbox, and can maintain state across messages. Processes yield while waiting for I/O so other processes can run.

```lua
local function worker(initial_config)
    local inbox = process.inbox()
    local events = process.events()

    while true do
        local r = channel.select {
            inbox:case_receive(),
            events:case_receive()
        }

        if not r.ok then break end

        if r.channel == events then
            local ev = r.value
            if ev.kind == process.event.CANCEL then
                break
            end
        elseif r.channel == inbox then
            local msg = r.value
            local topic = msg:topic()
            local data, err = msg:payload():data()
            if err then return nil, err end

            if topic == "work" then
                -- Perform the application-specific work here.
                print(data.item_id)
            end
        end
    end
end

return worker
```

Spawn processes from other code:

```lua
local pid, err = process.spawn("app.workers:task", "app:process_host", config)
if err then return nil, err end

local ok, send_err = process.send(pid, "work", {item_id = 123})
if send_err then return nil, send_err end
return ok
```



## Writing Workflows


Workflows persist execution history so they can resume after crashes or restarts. Workflow code uses normal Lua syntax, while the runtime records function results, sleeps, and random values for deterministic replay.

Each `funcs.call()` target below must be registered as an activity on the same
Temporal worker through `meta.temporal.activity.worker`. See
[Activities](../temporal/activities.md) for the required function metadata.

```lua
local funcs = require("funcs")

local function compensate(inventory, payment)
    local _, refund_err = funcs.call("app:refund_payment", payment.id)
    local _, release_err = funcs.call("app:release_inventory", inventory.id)
    return refund_err or release_err
end

local function order_flow(order)
    local inventory, err = funcs.call("app:reserve_inventory", order.items)
    if err then return nil, err end

    local payment, payment_err = funcs.call("app:charge_payment", order.total)
    if payment_err then
        local _, release_err = funcs.call("app:release_inventory", inventory.id)
        return nil, release_err or payment_err
    end

    -- Wait for approval signal (can block for days)
    local msg, open = process.inbox():receive()
    if not open then
        local compensation_err = compensate(inventory, payment)
        return nil, compensation_err or errors.new("workflow inbox closed")
    end

    local decision, payload_err = msg:payload():data()
    if payload_err then
        local compensation_err = compensate(inventory, payment)
        return nil, compensation_err or payload_err
    end
    if not decision.approved then
        local compensation_err = compensate(inventory, payment)
        return nil, compensation_err or errors.new("rejected")
    end

    return funcs.call("app:fulfill_order", order.id)
end

return order_flow
```



### Calling Functions


```lua
local funcs = require("funcs")

-- Synchronous
local result, err = funcs.call("namespace:function_name", arg1, arg2)
if err then return nil, err end

-- Asynchronous (returns Future)
local future, future_err = funcs.async("namespace:function_name", arg1)
if future_err then return nil, future_err end
local response_ch = future:response()
local _, response_open = response_ch:receive()
if not response_open then
    return nil, errors.new("future response channel closed")
end
local async_payload, async_err = future:result()
if async_err then return nil, async_err end
local async_result, decode_err = async_payload:data()
if decode_err then return nil, decode_err end

-- With context
local contextual_exec, contextual_err = funcs.new():with_context({user_id = "123"})
if contextual_err then return nil, contextual_err end
local contextual_result, contextual_err = contextual_exec:call("namespace:function_name")
if contextual_err then return nil, contextual_err end
```



### Process Communication


```lua
-- Send message (fire-and-forget)
local ok, err = process.send(pid, "topic", data)
if err then return nil, err end

-- Receive messages
local inbox = process.inbox()
local msg, ok = inbox:receive()
if not ok then return nil, errors.new("process inbox closed") end
local topic = msg:topic()
local data, payload_err = msg:payload():data()
if payload_err then return nil, payload_err end

-- Monitor another process (receive EXIT on death)
local monitored, monitor_err = process.monitor(pid)
if monitor_err then return nil, monitor_err end

-- Link processes (bidirectional failure notification)
local linked_pid, spawn_err = process.spawn_linked("namespace:name", "host")
if spawn_err then return nil, spawn_err end
```



### Channels


Go-style channels for coroutine communication:

```lua
local ch = channel.new(10)  -- buffered
ch:send(value)
local val, ok = ch:receive()

-- Select on multiple channels
local r = channel.select {
    ch1:case_receive(),
    ch2:case_receive(),
    timeout:case_receive()
}
```



### Error Handling


Functions return `result, error` pairs. Errors are typed objects:

```lua
local result, err = some_operation()
if err then
    if errors.is(err, errors.NOT_FOUND) then
        -- handle not found
    end
    return nil, errors.wrap(err, "context message")
end
```

Error kinds: `UNKNOWN`, `INVALID`, `NOT_FOUND`, `ALREADY_EXISTS`, `PERMISSION_DENIED`, `TIMEOUT`, `CANCELED`, `UNAVAILABLE`, `INTERNAL`, `CONFLICT`, `RATE_LIMITED`.



### Data Access


```lua
-- SQL
local sql = require("sql")
local db = sql.get("app:main_db")
local rows, err = db:query("SELECT * FROM users WHERE active = $1", {true})
db:execute("INSERT INTO users (name) VALUES ($1)", {name})

-- Key-value store
local store = require("store")
local cache, cache_err = store.get("app:cache")
if cache_err then return nil, cache_err end
local stored, set_err = cache:set("key", value, 3600)  -- TTL in seconds
if set_err then
    cache:release()
    return nil, set_err
end
local val, get_err = cache:get("key")
cache:release()
if get_err then return nil, get_err end

-- Queue
local queue = require("queue")
local published, publish_err = queue.publish("app:tasks", {task = "process", id = 123})
if publish_err then return nil, publish_err end

-- Filesystem
local fs = require("fs")
local vol, volume_err = fs.get("app:storage")
if volume_err then return nil, volume_err end
local data, read_err = vol:readfile("path/to/file.txt")
if read_err then return nil, read_err end
local written, write_err = vol:writefile("output.txt", content)
if write_err then return nil, write_err end
```



### HTTP Client


```lua
local http_client = require("http_client")

local resp, err = http_client.get("https://api.example.com/data", {
    headers = {Authorization = "Bearer token"},
    timeout = "10s"
})
if err then return nil, err end
local body = resp.body
```



### Security


```lua
local security = require("security")

local actor = security.actor()       -- who is calling
local scope = security.scope()       -- what permissions apply
if not actor then return nil, errors.new("security actor unavailable") end
if not scope then return nil, errors.new("security scope unavailable") end
local allowed = security.can("read", "resource:users")

-- Token management
local ts, store_err = security.token_store("app:tokens")
if store_err then return nil, store_err end
local token, create_err = ts:create(actor, scope, {expiration = "24h"})
if create_err then
    ts:close()
    return nil, create_err
end
local validated_actor, validated_scope, validate_err = ts:validate(token)
ts:close()
if validate_err then return nil, validate_err end
```



### Time


```lua
local time = require("time")

time.sleep("5s")
local now = time.now()
local timeout = time.after("30s")  -- channel that fires once
local ticker = time.ticker("10s")  -- ticker:channel() fires every interval
```



### Registry


```lua
local registry = require("registry")

local entry, entry_err = registry.get("app.api:get_user")
if entry_err then return nil, entry_err end
local tests, find_err = registry.find({["meta.type"] = "test"})
if find_err then return nil, find_err end

-- Create entries at runtime
local snap, snapshot_err = registry.snapshot()
if snapshot_err then return nil, snapshot_err end
local changes, changes_err = snap:changes()
if changes_err then return nil, changes_err end
local _, create_err = changes:create({id = "app:new_func", kind = "function.lua", data = {...}})
if create_err then return nil, create_err end
local version, apply_err = changes:apply()
if apply_err then return nil, apply_err end
```



### Events


```lua
local events = require("events")

-- Publish
local sent, send_err = events.send("orders", "order.created", "/orders/123", {order_id = "123"})
if send_err then return nil, send_err end

-- Subscribe (wildcards supported)
local sub, subscribe_err = events.subscribe("orders.*")
if subscribe_err then return nil, subscribe_err end
local ch = sub:channel()
local evt, open = ch:receive()
sub:close()
if not open then return nil, errors.new("event subscription closed") end
```



## Module Access Control


Each entry receives the restricted base environment and standard libraries, and executable entries also receive the ambient `process` module. Add non-ambient runtime modules to `modules:` and registry-backed libraries to `imports:`. Undeclared non-ambient modules are unavailable. Host Lua facilities such as `os.execute`, `io.open`, `debug.*`, native module loading, and arbitrary `package.path` resolution are not exposed as opt-in runtime modules. The runtime controls availability through its module loader rather than by scanning source code.

```yaml
modules: [sql, json, http, time, funcs, store]
```

Workflow entries receive only deterministic modules. The runtime intercepts `time.now()`, `uuid.v4()`, and other non-deterministic calls at the module level, recording results for replay.



## Framework Modules


Framework capabilities are distributed as dependencies:

- **wippy/llm** — LLM integration (OpenAI, Anthropic, Google). `llm.generate()`, structured output, embeddings, streaming.
- **wippy/agent** — Agent framework with tool use, delegation, traits, memory. Agents defined as registry entries.
- **wippy/test** — BDD testing. `describe/it` blocks, assertions, mocking.
- **wippy/dataflow** — DAG-based workflow orchestration. Function, agent, cycle, parallel nodes.
- **wippy/relay** — WebSocket relay with central hub, per-user hubs, plugin routing.
- **wippy/views** — Page and component system with template rendering.
- **wippy/facade** — Frontend facade and authentication bridge for iframe and Web Fragment pages.



## Conventions


- Entry IDs use `namespace:name` format
- Names use dots for semantic separation, underscores for words: `get_user.endpoint`
- Fallible APIs return `result, error` — always check the error
- Processes communicate via message passing, never shared state
- Use `channel.select` to multiplex multiple event sources
- Let supervision trees handle process failures instead of adding local recovery around every operation
- Context (trace IDs, user info, security) propagates automatically through function calls
- Workflows must not use non-deterministic operations directly — the runtime handles this for `funcs.call`, `time.sleep`, `uuid.v4`, `time.now`



## Documentation


Full documentation is available at [docs.wippy.ai](https://docs.wippy.ai). LLM-friendly endpoints:

- Browse structure: `https://wippy.ai/llm/toc`
- Search: `https://wippy.ai/llm/search?q=query`
- Fetch page: `https://wippy.ai/llm/path/en/<path>`
- Batch fetch: `https://wippy.ai/llm/context?paths=path1,path2`



## Navigation

Previous: "License" (about/license)
