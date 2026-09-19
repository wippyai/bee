# "YAML Encoding"

_Path: en/lua/data/yaml_

> "Parse YAML documents into Lua tables and serialize Lua values to YAML strings."

## Table of Contents

- YAML Encoding

## Content

# YAML Encoding

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>
<secondary-label ref="encoding"/>

The `yaml` module serializes Lua tables as YAML and parses YAML documents into Lua values.

This is an API reference. Output-only expressions illustrate successful encoding; examples that consume a value capture the optional second `error` return.



## Loading


```lua
local yaml = require("yaml")
```

Add `yaml` to the executable entry's `modules:` list before requiring it.



### `encode`


Encode a Lua table as YAML:

```lua
-- Simple key-value
local config = {
    name = "myapp",
    port = 8080,
    debug = true
}
local out, err = yaml.encode(config)
if err then return nil, err end
-- YAML mapping containing name, port, and debug.

-- Arrays become YAML lists
local items = {"apple", "banana", "cherry"}
yaml.encode(items)
-- - apple
-- - banana
-- - cherry

-- Nested structures
local server = {
    http = {
        address = ":8080",
        timeout = "30s"
    },
    database = {
        host = "localhost",
        port = 5432
    }
}
yaml.encode(server)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | table | Lua table to encode |
| `options` | table? | Optional encoding options |



#### Options


| Field | Type | Description |
|-------|------|-------------|
| `field_order` | string[] | Custom field order; listed fields appear in this order |
| `sort_unordered` | boolean | Sort fields not in `field_order` alphabetically |

```lua
-- Control field order in output
local entry = {
    zebra = 1,
    alpha = 2,
    name = "test",
    kind = "demo"
}

-- Fields appear in specified order, remaining sorted alphabetically
local result, encode_err = yaml.encode(entry, {
    field_order = {"name", "kind"},
    sort_unordered = true
})
if encode_err then return nil, encode_err end
-- name: test
-- kind: demo
-- alpha: 2
-- zebra: 1

-- Just sort all fields alphabetically
yaml.encode(entry, {sort_unordered = true})
-- alpha: 2
-- kind: demo
-- name: test
-- zebra: 1
```

**Returns:** `string, error`



### `decode`


Parse a YAML string into a Lua value:

```lua
-- Parse configuration
local config, err = yaml.decode([[
server:
  host: localhost
  port: 8080
features:
  - auth
  - logging
  - metrics
]])
if err then
    return nil, err
end

print(config.server.host)     -- "localhost"
print(config.server.port)     -- 8080
print(config.features[1])     -- "auth"

-- Parse from file content
local content = fs.get("app:config"):readfile("config.yaml")
local settings, err = yaml.decode(content)
if err then
    return nil, errors.wrap(err, "invalid config file")
end

-- Handle mixed types
local data, data_err = yaml.decode([[
name: test
count: 42
ratio: 3.14
enabled: true
tags:
  - lua
  - wippy
]])
if data_err then return nil, data_err end
print(type(data.count))    -- "number"
print(type(data.enabled))  -- "boolean"
print(type(data.tags))     -- "table"
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | YAML string to parse |

**Returns:** `any, error` — the value type depends on the YAML content



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Input not a table (encode) | `errors.INVALID` | no |
| Input not a string (decode) | `errors.INVALID` | no |
| Empty string (decode) | `errors.INVALID` | no |
| Invalid YAML syntax | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "JSON Encoding" (lua/data/json)
Next: "Base64 Encoding" (lua/data/base64)
