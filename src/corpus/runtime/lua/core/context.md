# "Request Context"

_Path: en/lua/core/context_

> "Access request-scoped context values. Context is set via Funcs or Process."

## Table of Contents

- Request Context

## Content

# Request Context

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The `ctx` module reads request-scoped values propagated through [function calls](lua/core/funcs.md) or [process operations](lua/core/process.md). This page is an API reference; the snippets show individual calls inside an executable Lua entry.



## Loading


```lua
local ctx = require("ctx")
```



### Get a Value


```lua
local value, err = ctx.get("key")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Context key |

**Returns:** `any, error`



### Get All Values


```lua
local values, err = ctx.all()
```

**Returns:** `table, error`

`ctx.all()` returns an empty table when an execution context is present but has no request values. A missing execution context returns `nil, errors.INTERNAL`.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty key | `errors.INVALID` | no |
| Key not found | `errors.NOT_FOUND` | no |
| No execution context available | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Streams" (lua/core/stream)
Next: "Event Bus" (lua/core/events)
