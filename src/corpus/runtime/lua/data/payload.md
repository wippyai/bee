# "Payload Encoding"

_Path: en/lua/data/payload_

> "Convert data between formats including JSON, MessagePack, and binary. Handle typed payloads for inter-service communication and workflow data passing."

## Table of Contents

- Payload Encoding

## Content

# Payload Encoding

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

Payloads carry typed values between functions, processes, services, and workflows. They can be inspected, extracted, or transcoded between supported formats.

This is an API reference with partial transport recipes. Values such as `p`, `input_data`, and the asynchronous target entry come from the surrounding application.



## Loading


`payload` is a global namespace and does not require `require()`.

```lua
payload.new(...)  -- direct access
```



## Format Constants


The following constants identify payload formats:

```lua
payload.format.JSON     -- "json/plain"
payload.format.YAML     -- "yaml/plain"
payload.format.STRING   -- "text/plain"
payload.format.BYTES    -- "application/octet-stream"
payload.format.MSGPACK  -- "application/msgpack"
payload.format.LUA      -- "lua/any"
payload.format.GOLANG   -- "golang/any"
payload.format.ERROR    -- "golang/error"
```



## Creating Payloads


Create a payload from a Lua value:

```lua
-- From table
local p = payload.new({
    user_id = 123,
    name = "Alice",
    roles = {"admin", "user"}
})

-- From string
local str_p = payload.new("Hello, World!")

-- From number
local num_p = payload.new(42.5)

-- From boolean
local bool_p = payload.new(true)

-- From nil
local nil_p = payload.new(nil)

-- From error
local err_p = payload.new(errors.new("something failed"))
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | any | Lua value (string, number, boolean, table, nil, or error) |

**Returns:** `Payload`



## Getting Format


Read the payload's format identifier:

```lua
local p = payload.new({name = "test"})
local format = p:get_format()  -- "lua/any"

local str_p = payload.new("hello")
local format2 = str_p:get_format()  -- "lua/any"

local err_p = payload.new(errors.new("failed"))
local format3 = err_p:get_format()  -- "golang/error"
```

**Returns:** `string` - one of `payload.format.*` constants



## Extracting Data


Extract the payload's Lua value, transcoding when needed:

```lua
local p = payload.new({
    items = {1, 2, 3},
    total = 100
})

local data, err = p:data()
if err then
    return nil, err
end

print(data.total)        -- 100
print(data.items[1])     -- 1
```

**Returns:** `any, error`



## Transcoding Payloads


Transcode a payload to another supported format:

```lua
local p = payload.new({
    name = "test",
    value = 123
})

-- Convert to JSON
local json_p, err = p:transcode(payload.format.JSON)
if err then
    return nil, err
end
print(json_p:get_format())  -- "json/plain"

-- Convert to MessagePack (compact binary)
local msgpack_p, err = p:transcode(payload.format.MSGPACK)
if err then
    return nil, err
end

-- Convert to YAML
local yaml_p, yaml_err = p:transcode(payload.format.YAML)
if yaml_err then
    return nil, yaml_err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `format` | string | Target format from `payload.format.*` |

**Returns:** `Payload, error`



## Unmarshalling


Decode a payload to a Lua value regardless of its source format:

```lua
local data, err = p:unmarshal()
if err then
    return nil, err
end
```

`unmarshal()` behaves like `data()`: both transcode non-Lua payloads to the Lua format and return the resulting Lua value. The only difference is that `unmarshal()` returns an error when the transcoded data is not a valid Lua value, whereas `data()` returns `nil`.

**Returns:** `any, error`



## Async Results


Asynchronous function calls return their values in payloads:

This example assumes `app.process:compute` returns exactly one value. With no result, `future:result()` returns `nil`; with multiple results, it returns a Lua table rather than one `Payload`, so callers must handle those shapes separately.

```lua
local funcs = require("funcs")

local future, err = funcs.async("app.process:compute", input_data)
if err then
    return nil, err
end

-- Wait for result
local ch = future:response()
local _, ok = ch:receive()
if not ok then
    return nil, errors.new("channel closed")
end

local result_payload, result_err = future:result()
if result_err then
    return nil, result_err
end
if result_payload == nil then
    return nil, errors.new("compute returned no result")
end

-- Extract data from payload
local result, err = result_payload:data()
if err then
    return nil, err
end

print(result.computed_value)
```



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Transcoding failure | `errors.INTERNAL` | no |
| Result not valid Lua value | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Archive" (lua/data/archive)
Next: "Excel Spreadsheets" (lua/data/excel)
