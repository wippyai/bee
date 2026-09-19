# "Futures"

_Path: en/lua/core/future_

> "Asynchronous operation results. Futures are returned by funcs.async() and contract async calls."

## Table of Contents

- Futures

## Content

# Futures

<secondary-label ref="function"/>
<secondary-label ref="process"/>

Futures represent asynchronous operation results. They are returned by `funcs.async()` and asynchronous contract calls. This page is an API reference; the target IDs and arguments in its patterns are application-defined.



## Loading


Futures are not loaded as a module; asynchronous operations create them:

```lua
local funcs = require("funcs")
local future, err = funcs.async("app.compute:task", data)
if err then
    return nil, err
end
```



## Response Channel


Use the response channel to wait for completion, then read the cached result from the future:

```lua
local ch = future:response()
local _, open = ch:receive()
if not open then
    return nil, errors.new("future response channel closed")
end

local payload, err = future:result()
if err then
    return nil, err
end
local result, data_err = payload:data()
if data_err then return nil, data_err end
```

`channel()` is an alias for `response()`.

The channel value is the operation's payload, payload table, or error. Calling `result()` after the channel becomes ready provides one consistent success/error interface and returns the cached value even after the channel is drained.



## Completion Check


Check whether the future has completed without blocking:

```lua
if future:is_complete() then
    local result, err = future:result()
end
```



## Cancellation Check


Check whether the future has been marked canceled by its provider:

```lua
if future:is_canceled() then
    print("Operation was canceled")
end
```



## Getting Result


Read the cached result without blocking:

```lua
local val, err = future:result()
```

**Returns:**

- Not complete: `nil, nil`
- Canceled: `nil, error` (kind `CANCELED`)
- Error: `nil, error`
- Success: `Payload, nil` or `table, nil` (multiple payloads)



## Getting Error


Read the error when the future has failed:

```lua
local err, has_error = future:error()
if has_error then
    print("Failed:", err:message())
end
```

**Returns:** `error, boolean`

When an operation fails, `error()` returns a non-retryable `INTERNAL` wrapper. Use `result()` when the called function's original error kind and retryability must be preserved.



## Canceling


Request cancellation of the asynchronous operation on a best-effort basis:

```lua
local canceled, err = future:cancel()
```

**Returns:** `boolean, error`

Operation may still complete if already in progress.



## Timeout Pattern


```lua
local time = require("time")

local future, err = funcs.async("app.compute:slow", data)
if err then
    return nil, err
end

local timeout, err = time.after("5s")
if err then
    return nil, err
end

local r = channel.select {
    future:channel():case_receive(),
    timeout:case_receive()
}

if r.channel == timeout then
    future:cancel()
    return nil, errors.new({ kind = errors.TIMEOUT, message = "Operation timed out" })
end

local payload, result_err = future:result()
if result_err then
    return nil, result_err
end
local value, data_err = payload:data()
if data_err then return nil, data_err end
return value
```



## First-to-Complete


```lua
local f1, err = funcs.async("app.cache:get", key)
if err then
    return nil, err
end
local f2, err = funcs.async("app.db:get", key)
if err then
    return nil, err
end

local ch1 = f1:channel()
local ch2 = f2:channel()

local r = channel.select {
    ch1:case_receive(),
    ch2:case_receive()
}

-- The slower operation may still complete; this caller ignores its result.
local winner
if r.channel == ch1 then
    winner = f1
else
    winner = f2
end

local payload, result_err = winner:result()
if result_err then
    return nil, result_err
end
local value, data_err = payload:data()
if data_err then return nil, data_err end
return value
```



## Errors


| Condition | Kind |
|-----------|------|
| Operation canceled | `CANCELED` |
| Async operation failed | `result()` preserves the operation's kind; `error()` reports `INTERNAL` |



## Navigation

Previous: "Function Invocation" (lua/core/funcs)
Next: "Streams" (lua/core/stream)
