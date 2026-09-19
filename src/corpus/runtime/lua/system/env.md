# "Environment Variables"

_Path: en/lua/system/env_

> "Access environment variables for configuration values, secrets, and runtime settings."

## Table of Contents

- Environment Variables

## Content

# Environment Variables

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="permissions"/>

The `env` module reads and updates environment variables exposed by the runtime.

This is an API reference. Its snippets are isolated operations and assume the named variables and security policies already exist.

Variables must be defined in the [Environment System](system/env.md) before they can be accessed. The system controls which storage backends (OS, file, memory) provide values and whether variables are read-only.



## Loading


```lua
local env = require("env")
```



## `get`


Retrieve an environment variable.

```lua
-- Get database connection string
local db_url = env.get("DATABASE_URL")
if not db_url then
    return nil, errors.new({ kind = errors.INVALID, message = "DATABASE_URL not configured" })
end

local port, port_err = get_or("PORT", "8080")
if port_err then return nil, port_err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Variable name |

**Returns:** `string, error`

The function returns `nil, error` when the variable does not exist.



## `set`


Set an environment variable.

```lua
-- Set runtime configuration
local updated, set_err = env.set("APP_MODE", "production")
if set_err then return nil, set_err end
return updated
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Variable name |
| `value` | string | Value to set |

**Returns:** `boolean, error`



## `get_all`


Retrieve all environment variables accessible to the caller.

```lua
local logger = require("logger")

local vars, vars_err = env.get_all()
if vars_err then return nil, vars_err end

-- Log names only. Values such as connection URLs may contain credentials even
-- when their keys do not include words like SECRET or KEY.
local accessible_keys = {}
for key in pairs(vars) do table.insert(accessible_keys, key) end
logger:debug("accessible environment variables", {keys = accessible_keys})

-- Check required variables
local required = {"DATABASE_URL", "REDIS_URL", "API_KEY"}
for _, key in ipairs(required) do
    if not vars[key] then
        return nil, errors.new({ kind = errors.INVALID, message = "Missing required env var: " .. key })
    end
end
```

**Returns:** `table, error`



## Permissions


Security policy evaluation applies to environment access.



### Security Actions


| Action | Resource | Description |
|--------|----------|-------------|
| `env.get` | Variable name | Read environment variable |
| `env.set` | Variable name | Write environment variable |

`get_all` has no dedicated security action: it returns only the variables for which the `env.get` action is permitted, filtering each variable name through `env.get`.



### Checking Access


```lua
local security = require("security")

if security.can("env.get", "DATABASE_URL") then
    local url = env.get("DATABASE_URL")
end
```

See [Security Model](system/security.md) for policy configuration.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty key | `errors.INVALID` | no |
| Variable not found | `errors.NOT_FOUND` | no |
| Permission denied | `errors.PERMISSION_DENIED` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Environment System](system/env.md) - Configure storage backends and variable definitions



## Navigation

Previous: "System" (lua/system/system)
Next: "Logging" (lua/system/logger)
