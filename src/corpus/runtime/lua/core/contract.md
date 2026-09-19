# "Contracts"

_Path: en/lua/core/contract_

> "Invoke services through typed contracts. Call remote APIs, workflows, and functions with schema validation and async execution support."

## Table of Contents

- Contracts

## Content

# Contracts

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>
<secondary-label ref="permissions"/>

The `contract` module opens typed service bindings for remote APIs, workflows, and functions. Contracts support schema validation, asynchronous calls, and call-context propagation. This page is an API reference; IDs and values such as `current_user` represent application-owned entries and surrounding handler state.



## Loading


```lua
local contract = require("contract")
```



## Opening a Binding


Open a binding by its registry ID:

```lua
local greeter, err = contract.open("app.services:greeter")
if err then
    return nil, err
end

local result, err = greeter:say_hello("Alice")
if err then
    return nil, err
end
```

Bindings can also receive scope values, query parameters, or call options:

```lua
-- With scope table
local svc, err = contract.open("app.services:user", {
    tenant_id = "acme",
    region = "us-east"
})

-- With query parameters (auto-converted: "true"→bool, numbers→int/float)
local api, err = contract.open("app.services:api?debug=true&timeout=5000")

-- With call options (third argument)
local inst, err = contract.open("app.services:flaky", nil, {
    retry = { max_attempts = 5, initial_delay = 100 }
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `binding_id` | string | Binding ID; query parameters are supported |
| `scope` | table | Context values (optional, overrides query params) |
| `options` | table | Call options (optional) — e.g. `retry.max_attempts`, `retry.initial_delay` |

**Returns:** `Instance, error`



## Getting a Contract


Retrieve a contract definition for introspection:

```lua
local c, err = contract.get("app.services:greeter")
if err then
    return nil, err
end

print(c:id())  -- "app.services:greeter"

local methods = c:methods()
for _, m in ipairs(methods) do
    print(m.name, m.description)
end

local method, err = c:method("say_hello")
if err then
    return nil, err
end
```



### Method Definition


| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Method name |
| `description` | string | Method description |
| `input_schemas` | table[] | Input schema definitions (absent when the method declares none) |
| `output_schemas` | table[] | Output schema definitions (absent when the method declares none) |



## Finding Implementations


List the bindings that implement a contract:

```lua
local bindings, err = contract.find_implementations("app.services:greeter")
if err then
    return nil, err
end

for _, binding_id in ipairs(bindings) do
    print(binding_id)
end
```

The same lookup is available on a contract object:

```lua
local c, err = contract.get("app.services:greeter")
if err then
    return nil, err
end
local bindings, err = c:implementations()
if err then
    return nil, err
end
```



## Checking Implementation


Check whether an already opened instance implements a contract:

```lua
if contract.is(instance, "app.services:greeter") then
    instance:say_hello("World")
end
```



## Calling Methods


A synchronous method call blocks until it completes:

```lua
local calc, err = contract.open("app.services:calculator")
if err then
    return nil, err
end

local sum, err = calc:add(10, 20)
if err then
    return nil, err
end
local product, err = calc:multiply(5, 6)
if err then
    return nil, err
end
```



## Async Calls


Append `_async` to a method name to start it asynchronously:

```lua
local processor, err = contract.open("app.services:processor")
if err then
    return nil, err
end

local future, err = processor:process_async(large_dataset)
if err then
    return nil, err
end

-- Do other work...

-- Wait for result
local ch = future:response()
local _, open = ch:receive()
if not open then
    return nil, errors.new("future response channel closed")
end

local payload, result_err = future:result()
if result_err then return nil, result_err end
local result, data_err = payload:data()
if data_err then return nil, data_err end
```

See [Futures](lua/core/future.md) for future methods.



## Opening via Contract


Open a binding through a contract object. The calls below are alternatives; check the error returned by `contract.get()` and by the selected `open()` call before using the instance.

```lua
local c, err = contract.get("app.services:user")
if err then
    return nil, err
end

-- Default binding
local instance, err = c:open()

-- Specific binding
local instance, err = c:open("app.services:user_impl")

-- With scope
local instance, err = c:open(nil, {user_id = 123})
local instance, err = c:open("app.services:user_impl", {user_id = 123})
```



## Adding Context


Create a wrapper with preconfigured context values:

```lua
local ctx = require("ctx")
local c, err = contract.get("app.services:user")
if err then return nil, err end

local request_id, ctx_err = ctx.get("request_id")
if ctx_err then return nil, ctx_err end

local wrapped, err = c:with_context({
    request_id = request_id,
    user_id = current_user.id
})
if err then return nil, err end

local instance, err = wrapped:open()
```



## Call Options


Use `with_options` to configure retries and other call behavior:

```lua
local c, err = contract.get("app.services:flaky")
if err then return nil, err end

local configured = c:with_options({
    retry = { max_attempts = 5, initial_delay = 100 }
})
local inst, err = configured:open("app.services:flaky_impl")
if err then return nil, err end

local result, err = inst:call()
```

Options apply to every method call on the returned instance. Only retryable errors trigger retries; non-retryable errors return immediately. `with_options` can be chained with `with_context`, `with_actor`, and `with_scope`.

| Option | Type | Description |
|--------|------|-------------|
| `retry.max_attempts` | int | Maximum attempts including the first (1 disables retry) |
| `retry.initial_delay` | int/duration | Delay before first retry (ms or duration string), default `100` |
| `retry.max_delay` | int/duration | Upper bound for the backoff delay (ms or duration string), default `10s` |
| `retry.backoff_factor` | number | Multiplier applied to the delay after each attempt, default `2.0` |
| `retry.jitter` | number | Random jitter fraction applied to each delay, default `0.1` |
| `retry.retry_kinds` | string[] | Only retry errors of these kinds; by default every kind except `Invalid`, `PermissionDenied` and `Internal` is retried |
| `retry.skip_kinds` | string[] | Never retry errors of these kinds |



## Security Context


Set the actor and scope used for authorization:

```lua
local security = require("security")
local c, err = contract.get("app.services:admin")
if err then return nil, err end

local secured, err = c:with_actor(security.actor())
if err then return nil, err end

secured, err = secured:with_scope(security.scope())
if err then return nil, err end

local admin, err = secured:open()
if err then return nil, err end
```

Without explicit `with_actor`/`with_scope`, an opened contract inherits the caller's ambient actor and scope. When set, they propagate to the bound implementation functions — every method call on the instance executes under that identity.



## Permissions


| Permission | Resource | Functions |
|------------|----------|-----------|
| `contract.get` | contract id | `get()` |
| `contract.open` | binding id | `open()`, `Contract:open()` |
| `contract.implementations` | contract id | `find_implementations()`, `Contract:implementations()` |
| `contract.call` | method name | sync and async method calls |
| `contract.context` | "context" | `Contract:with_context()` |
| `contract.security` | "security" | `Contract:with_actor()`, `Contract:with_scope()` |



## Errors


| Condition | Kind |
|-----------|------|
| Invalid binding ID format | `errors.INVALID` |
| Contract not found | `errors.NOT_FOUND` |
| Binding not found | `errors.NOT_FOUND` |
| Method not found | `errors.NOT_FOUND` |
| No default binding | `errors.NOT_FOUND` |
| Permission denied | `errors.PERMISSION_DENIED` |
| Call failed | kind of the implementation's error (preserved); `errors.INTERNAL` for dispatch failures |



## Navigation

Previous: "Entry Registry" (lua/core/registry)
Next: "JSON Encoding" (lua/data/json)
