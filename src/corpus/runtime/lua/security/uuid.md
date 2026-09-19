# "UUID Generation"

_Path: en/lua/security/uuid_

> "Generate universally unique identifiers. Adapted for workflows - random UUIDs return consistent values on replay."

## Table of Contents

- UUID Generation

## Content

# UUID Generation

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The `uuid` module generates, validates, inspects, parses, and formats UUIDs. In deterministic workflows, v1, v4, and v7 generation runs as a recorded side effect and returns the recorded value during replay. Namespace-based v3 and v5 generation is deterministic and runs directly.

This page is an API reference of isolated calls. Values such as `namespace`, `name`, `input`, and `id` come from the surrounding application. Capture and handle the second `error` return before consuming generated, parsed, inspected, or formatted results. UUIDs are identifiers, not bearer credentials; do not use any UUID version as an authentication token or secret.



## Loading


```lua
local uuid = require("uuid")
```



### Version 1


Time-based UUID with timestamp and node ID.

Version 1 exposes its creation time and node identifier. Avoid it where those details are sensitive; prefer v4 when only an opaque identifier is needed.

```lua
local id, err = uuid.v1()
```

**Returns:** `string, error`



### Version 4


Random UUID.

```lua
local id, err = uuid.v4()
```

**Returns:** `string, error`



### Version 7


A time-ordered UUID that encodes its creation time for chronological indexing. Do not rely on it as a strictly monotonic sequence, especially for values generated within the same timestamp interval.

```lua
local id, err = uuid.v7()
```

**Returns:** `string, error`



### Version 3


Deterministic UUID from namespace and name using MD5.

```lua
local id, err = uuid.v3(namespace, name)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `namespace` | string | Valid UUID string |
| `name` | string | Value to hash |

**Returns:** `string, error`



### Version 5


Deterministic UUID from namespace and name using SHA-1.

```lua
local NS_URL = "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
local id, err = uuid.v5(NS_URL, "https://example.com/resource")
if err then
    return nil, err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `namespace` | string | Valid UUID string |
| `name` | string | Value to hash |

**Returns:** `string, error`



### `validate`


```lua
local valid = uuid.validate(input)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `input` | any | Value to check |

**Returns:** `boolean, nil`. Non-string and malformed inputs return `false`; validation does not raise a structured error.



### `version`


```lua
local ver, err = uuid.version(id)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `uuid` | string | Valid UUID string |

**Returns:** `integer, error`



### `variant`


```lua
local var, err = uuid.variant(id)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `uuid` | string | Valid UUID string |

**Returns:** `string, error` (RFC4122, Reserved, Microsoft, Future, NCS, or Invalid)



### `parse`


```lua
local info, err = uuid.parse(id)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `uuid` | string | Valid UUID string |

**Returns:** `table, error`

Returned table fields:
- `version` (integer): UUID version (1, 3, 4, 5, or 7)
- `variant` (string): RFC4122, Reserved, Microsoft, Future, NCS, or Invalid
- `timestamp` (integer): Unix timestamp (v1 and v7 only)
- `node` (string): 6 raw node ID bytes (v1 only)



### `format`


```lua
local formatted, err = uuid.format(id, "standard")
local formatted, err = uuid.format(id, "simple")
local formatted, err = uuid.format(id, "urn")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `uuid` | string | Valid UUID string |
| `format` | string? | standard (default), simple, or urn |

**Returns:** `string, error`



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Invalid input type | `errors.INVALID` | no |
| Invalid UUID format | `errors.INVALID` | no |
| Unsupported format type | `errors.INVALID` | no |
| Generation failed | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Hash Functions" (lua/security/hash)
Next: "Dynamic Evaluation" (lua/dynamic/eval)
