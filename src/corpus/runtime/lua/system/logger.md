# "Logging"

_Path: en/lua/system/logger_

> "Structured logging with debug, info, warn, and error levels."

## Table of Contents

- Logging

## Content

# Logging

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>

The `logger` module writes structured messages at debug, info, warn, and error levels.

This is an API reference. Each snippet is an isolated logging operation and assumes an execution context with the desired logger configuration.

Log calls return no values. When the execution context provides them, each call also adds the process `pid` and the source `location` derived from the current frame.



## Loading


```lua
local logger = require("logger")
```



### `logger:debug`


Write a debug-level log message.

```lua
logger:debug("message", {key = "value"})
```



### `logger:info`


Write an info-level log message.

```lua
logger:info("message", {key = "value"})
```



### `logger:warn`


Write a warning-level log message.

```lua
logger:warn("message", {key = "value"})
```



### `logger:error`


Write an error-level log message.

```lua
logger:error("message", {key = "value"})
```

All four log-level methods accept the same parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `message` | string | Log message |
| `fields` | table? | Contextual key-value pairs |

Only string keys become field names. Strings, numbers, integers, booleans, errors, and structured Lua values are converted to log fields; non-string keys are ignored.

For `logger:error`, a field named `error` is emitted as an error field and removed from the supplied table before the remaining fields are processed. Do not reuse that table if the `error` entry must remain intact.



### `logger:with`


Create a child logger that adds the same fields to every message.

```lua
local function request_logger(request_id)
    return logger:with({request_id = request_id})
end

request_logger("req-123"):info("message")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `fields` | table | Fields to attach to all logs |

**Returns:** `Logger`

The original logger is unchanged. Child loggers can be chained with additional `with` and `named` calls.



### `logger:named`


Create a child logger with a name.

```lua
local named = logger:named("auth")
named:info("message")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Logger name |

**Returns:** `Logger`

An empty name raises a Lua argument error. It is not returned as a structured `errors.INVALID` value.

`logger:named("")` raises a Lua argument error (`name cannot be empty`) instead of returning an error value. Logging methods return nothing.

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Environment Variables" (lua/system/env)
Next: "Terminal I/O" (lua/system/io)
