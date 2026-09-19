# "Functions"

_Path: en/concepts/functions_

> "How to define and call functions, propagate context, configure pools, and apply interceptors."

## Table of Contents

- Functions

## Content

# Functions


Functions are call-and-return entry points. A function inherits its caller's
context and is canceled when the caller is canceled. Pools can reuse Lua states,
so module globals and closure upvalues may survive on one worker but are not
shared consistently across calls. Store durable or shared state outside the
function. Use functions for HTTP handlers, API endpoints, and other operations
that complete within a request lifecycle.



## Calling Functions


Call functions synchronously with `funcs.call()`:

```lua
local funcs = require("funcs")
local result, err = funcs.call("app.api:get_user", user_id)
if err then return nil, err end
return result
```

For non-blocking execution, use `funcs.async()`:

```lua
local future, err = funcs.async("app.process:analyze", data)
if err then
    return nil, err
end

local ch = future:response()
local payload, open = ch:receive()
if not open then
    return nil, "future response channel closed"
end

local result, err = payload:data()
if err then
    return nil, err
end
```

See the [funcs module](lua/core/funcs.md) for function invocation and executor options.



## Context Propagation


Each call creates a frame with its own context scope. Child functions inherit parent context without explicit passing:

```lua
local ctx = require("ctx")

local trace_id = ctx.get("trace_id")
local user_id = ctx.get("user_id")
```

Add context when calling:

```lua
local funcs = require("funcs")

local exec, err = funcs.new():with_context({trace_id = "abc-123"})
if err then return nil, err end

local result, err = exec:call("app.api:process", data)
if err then return nil, err end
return result
```

Security context propagates the same way. Called functions see the caller's actor and can check permissions. See the [security module](lua/security/security.md) for access control APIs.



## Registry Definition


At the registry level, a function entry looks like this:

```yaml
- name: get_user
  kind: function.lua
  source: file://handlers/user.lua
  method: get
  pool:
    type: lazy
    max_size: 16
```

Functions can be invoked by other runtime components—HTTP handlers, queue consumers, scheduled jobs—and are subject to permission checks based on the caller's security context.



## Pools


Functions run on pools that manage execution. The pool type determines scaling behavior.

**Inline** runs in the caller's goroutine without a worker pool. It is used for embedded contexts.

**Static** maintains a fixed number of workers. Requests queue when all workers are busy, which keeps worker concurrency fixed.

```yaml
pool:
  type: static
  size: 8
  buffer: 512
```

**Lazy** starts without workers and creates them on demand. Idle workers are removed after a timeout.

```yaml
pool:
  type: lazy
  max_size: 32
```

**Adaptive** adjusts the worker count based on measured throughput and current load.

```yaml
pool:
  type: adaptive
  max_size: 256
```

<tip>
If you don't specify a pool type, the runtime selects one based on your configuration. Set `workers` for static, `max_size` for lazy, or explicitly set `type` for full control. With neither set, the pool is lazy with a maximum of 16 workers.
</tip>



## Interceptors


Function calls pass through an interceptor chain. Interceptors can handle cross-cutting concerns separately from the function implementation.

```yaml
- name: my_function
  kind: function.lua
  source: file://handler.lua
  method: main
  meta:
    options:
      retry:
        max_attempts: 3
        initial_delay: 100
        backoff_factor: 2.0
```

Built-in interceptors include retry with exponential backoff. Runtime
integrations written in Go can register additional interceptors for logging,
metrics, tracing, authorization, circuit breaking, or request transformation;
Lua application entries can configure only interceptors installed by the
runtime.

The chain runs before and after each call. Each interceptor can modify the request, short-circuit execution, or wrap the response.



## Contracts


Functions can expose their input/output schemas as contracts. Contracts define method signatures that enable runtime validation and documentation generation.

```lua
local contract = require("contract")
local sender, err = contract.get("app.email:sender")
if err then return nil, err end

local email, err = sender:open("app.email:sender_impl")
if err then return nil, err end

local result, err = email:send({to = "user@example.com", subject = "Hello"})
if err then return nil, err end
return result
```

Contracts allow callers to use an interface while selecting an implementation separately. This supports testing, multi-tenant deployments, and gradual migrations.



## Functions vs Processes


Functions inherit the caller's context and lifecycle. When the caller is canceled, its function calls are canceled as well. This suits execution within HTTP handlers and queue consumers.

Processes run independently with host context. They outlive their creator and communicate through messages. Use processes for background work; use functions for request-scoped operations.



## Navigation

Previous: "Cluster" (concepts/cluster)
Next: "Workflows" (concepts/workflows)
