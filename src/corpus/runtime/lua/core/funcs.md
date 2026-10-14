# "Function Invocation"

_Path: en/lua/core/funcs_

> "The primary way to call other functions in Wippy. Execute registered functions synchronously or asynchronously across processes, with full support…"

## Table of Contents

- Function Invocation

## Content

# Function Invocation

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The `funcs` module calls registered functions synchronously or asynchronously. An executor can propagate request context, security identity, and implementation-specific call options. This page is an API reference; target IDs, arguments, and application data represent surrounding code.



## Loading


```lua
local funcs = require("funcs")
```



## `call`


Calls a registered function synchronously and waits for its result.

```lua
local result, err = funcs.call("app.api:get_user", user_id)
if err then
    return nil, err
end
print(result.name)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `target` | string | Function ID in format "namespace:name" |
| `...args` | any | Arguments passed to the function |

**Returns:** `result, error`

The target uses the `namespace:name` format.



## `async`


Starts a function call and returns a `Future` immediately. Futures allow other work to continue while the call runs and support multiple concurrent calls.

```lua
-- Start heavy computation without blocking
local future, err = funcs.async("app.process:analyze_data", large_dataset)
if err then
    return nil, err
end

-- Do other work while computation runs...

-- Wait for result when ready
local ch = future:response()
local _, open = ch:receive()
if not open then
    return nil, errors.new("future response channel closed")
end

local payload, result_err = future:result()
if result_err then
    return nil, result_err
end
local result, data_err = payload:data()
if data_err then return nil, data_err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `target` | string | Function ID in format "namespace:name" |
| `...args` | any | Arguments passed to the function |

**Returns:** `Future, error`



## `new`


Creates an `Executor` for calls that need custom context, security identity, or call options.

```lua
local exec = funcs.new()
```

**Returns:** `Executor`



## Executor


An executor stores call context and options. Its configuration methods return new executor instances, allowing a base configuration to be reused.



### `with_context`


Adds request-scoped values that will be available to the called function, such as trace IDs, session data, or feature flags.

```lua
local ctx = require("ctx")

-- Propagate request context to downstream services
local request_id, ctx_err = ctx.get("request_id")
if ctx_err then return nil, ctx_err end

local exec, err = funcs.new():with_context({
    request_id = request_id,
    feature_flags = {dark_mode = true}
})
if err then return nil, err end

local user, err = exec:call("app.api:get_user", user_id)
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `values` | table | Key-value pairs to add to context |

**Returns:** `Executor, error`



### `with_actor`


Sets the security actor used for authorization checks in the called function.

```lua
local security = require("security")
local actor = security.actor()  -- Get current user's actor

-- Call admin function with user's credentials
local exec, err = funcs.new():with_actor(actor)
if err then return nil, err end
local result, err = exec:call("app.admin:delete_record", record_id)
if err and err:kind() == errors.PERMISSION_DENIED then
    return nil, errors.new({kind = errors.PERMISSION_DENIED, message = "User cannot delete records"})
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `actor` | Actor | Security actor (from security module) |

**Returns:** `Executor, error`



### `with_scope`


Sets the security scope for called functions. The scope defines the permissions available to the call.

```lua
local security = require("security")
local scope = security.new_scope()

local exec, err = funcs.new():with_scope(scope)
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `scope` | Scope | Security scope (from security module) |

**Returns:** `Executor, error`



### `with_options`


Sets call options such as the retry policy or the overlay network. Options are merged over any preset options of the target function entry.

```lua
-- Retry transient failures up to 5 times with exponential backoff
local exec = funcs.new():with_options({
    retry = { max_attempts = 5, initial_delay = 100 }
})
local result, err = exec:call("app.external:fetch_data", query)
if err then
    -- All attempts failed, or the error was not retryable
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `options` | table | Call options |

| Option | Type | Description |
|--------|------|-------------|
| `retry.max_attempts` | int | Maximum attempts including the first (1 disables retry) |
| `retry.initial_delay` | int/duration | Delay before first retry (ms or duration string), default `100` |
| `retry.max_delay` | int/duration | Upper bound for the backoff delay (ms or duration string), default `10s` |
| `retry.backoff_factor` | number | Multiplier applied to the delay after each attempt, default `2.0` |
| `retry.jitter` | number | Random jitter fraction applied to each delay, default `0.1` |
| `retry.retry_kinds` | string[] | Only retry errors of these kinds; by default every kind except `Invalid`, `PermissionDenied` and `Internal` is retried |
| `retry.skip_kinds` | string[] | Never retry errors of these kinds |
| `network` | string | Registry ID of an overlay network to route the call's outbound traffic through; requires the `network.select` permission |

Only retryable errors trigger retries; non-retryable errors surface immediately. Temporal activity options are described in [Activities](temporal/activities.md).

The runtime-defined option is:

| Recognized option | Type | Description |
|-------------------|------|-------------|
| `network` | string | Registry ID of the outbound `network.*` entry |

**Returns:** `Executor, error`

Selecting a network requires `network.select` permission on that network ID.



### `call` and `async`


The executor versions of `call` and `async` use its configured context and options.

```lua
-- Build reusable executor with context
local exec = funcs.new()
    :with_context({trace_id = "abc-123"})
    :with_options({retry = {max_attempts = 3}})

-- Make multiple calls with same context
local users, users_err = exec:call("app.api:list_users")
if users_err then return nil, users_err end
local posts, posts_err = exec:call("app.api:list_posts")
if posts_err then return nil, posts_err end
```



## Future Invocation Summary


`async()` returns a future representing an in-progress invocation. The methods below cover the caller-facing steps for receiving, inspecting, or canceling that invocation. See [Future](./future.md) for the Future object reference.



### `response` and `channel`


Returns the channel used to receive the result.

```lua
local time = require("time")

local future, err = funcs.async("app.api:slow_operation", data)
if err then
    return nil, err
end
local ch = future:response()  -- or future:channel()

local timeout, err = time.after("5s")
if err then
    return nil, err
end

local result = channel.select {
    ch:case_receive(),
    timeout:case_receive()
}
```

**Returns:** `Channel`

The response channel signals completion. After it becomes ready, call `future:result()` to obtain the cached value or the called function's error.



### `is_complete`


Checks whether the future has completed without blocking.

```lua
while not future:is_complete() do
    -- do other work
    local _, sleep_err = time.sleep("100ms")
    if sleep_err then return nil, sleep_err end
end
local result, err = future:result()
```

**Returns:** `boolean`



### `is_canceled`


Returns `true` if the future has been marked canceled by its provider. See the cancellation limitation below.

```lua
if future:is_canceled() then
    print("Operation was canceled")
end
```

**Returns:** `boolean`



### `result`


Returns the cached result when complete or `nil` while the operation is pending.

```lua
local value, err = future:result()
if err then
    print("Failed:", err:message())
elseif value then
    local data, data_err = value:data()
    if data_err then return nil, data_err end
    print("Got:", data)
end
```

**Returns:** `Payload|table|nil, error|nil`



### `error`


Returns the operation error when the future has failed.

```lua
local err, has_error = future:error()
if has_error then
    print("Error kind:", err:kind())
end
```

**Returns:** `error|nil, boolean`

This method returns a non-retryable `INTERNAL` wrapper for a failed operation. Use `result()` to preserve the called function's original error metadata.



### `cancel`


Requests cancellation of the asynchronous operation.

```lua
local canceled, err = future:cancel()
if err then return nil, err end
```

**Returns:** `boolean, error`

<warning>
In runtime v0.3.32a, function and contract futures share one process-global cancellation callback. When both providers are loaded, <code>cancel()</code> and <code>is_canceled()</code> are not a stable cross-provider contract. Do not use cancellation for application correctness; time out locally and ignore a late result until the runtime separates provider cancellation.
</warning>



## Parallel Operations


Combine `async` with `channel.select` to run and collect multiple calls concurrently.

```lua
-- Start multiple operations in parallel
local f1, err = funcs.async("app.api:get_user", user_id)
if err then return nil, err end
local f2, err = funcs.async("app.api:get_orders", user_id)
if err then return nil, err end
local f3, err = funcs.async("app.api:get_preferences", user_id)
if err then return nil, err end

-- Wait for all to complete using channels
local user_ch = f1:channel()
local orders_ch = f2:channel()
local prefs_ch = f3:channel()

local pending = {
    [user_ch] = {name = "user", future = f1},
    [orders_ch] = {name = "orders", future = f2},
    [prefs_ch] = {name = "preferences", future = f3}
}
local results = {}
while next(pending) do
    local cases = {}
    for ch in pairs(pending) do
        cases[#cases + 1] = ch:case_receive()
    end

    local r = channel.select(cases)
    local completed = pending[r.channel]
    pending[r.channel] = nil

    local payload, result_err = completed.future:result()
    if result_err then
        return nil, result_err
    end
    local data, data_err = payload:data()
    if data_err then
        return nil, data_err
    end
    results[completed.name] = data
end
```



## Permissions


Function operations are subject to security policy evaluation.

| Action | Resource | Description |
|--------|----------|-------------|
| `funcs.call` | Function ID | Call a specific function |
| `funcs.context` | `context` | Use `with_context()` to set custom context |
| `funcs.security` | `security` | Use `with_actor()` or `with_scope()` |
| `network.select` | Network ID | Use `with_options({network = ...})` to select an overlay network |



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Target empty | `errors.INVALID` | no |
| Namespace missing | `errors.INVALID` | no |
| Name missing | `errors.INVALID` | no |
| Permission denied | `errors.PERMISSION_DENIED` | no |
| Async outside a process | `errors.INTERNAL` | no |
| Subscribe failed | `errors.INTERNAL` | no |
| Async start dispatch failed | `errors.INTERNAL` | no |
| Function error | varies | varies |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Process Groups" (lua/core/pg)
Next: "Futures" (lua/core/future)
