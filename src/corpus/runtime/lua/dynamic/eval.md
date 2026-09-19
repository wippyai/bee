# "Dynamic Evaluation"

_Path: en/lua/dynamic/eval_

> "Execute code dynamically at runtime with sandboxed environments and controlled module access."

## Table of Contents

- Dynamic Evaluation

## Content

# Dynamic Evaluation


Execute code dynamically at runtime with sandboxed environments and controlled module access.



## Two Systems


Wippy provides two evaluation systems:

| System | Purpose | Use Case |
|--------|---------|----------|
| `expr` | Expression evaluation | Config, templates, simple calculations |
| `eval_runner` | Full Lua execution | Plugins, user scripts, dynamic code |



## expr Module


Lightweight expression evaluation using the expr-lang syntax.

```lua
local expr = require("expr")

local result, err = expr.eval("x + y * 2", {x = 10, y = 5})
-- result = 20
```



### Compiling Expressions


Compile once, run many times:

```lua
local program, err = expr.compile("price * quantity")

local total1 = program:run({price = 10, quantity = 5})
local total2 = program:run({price = 20, quantity = 3})
```



### Supported Syntax


```lua
-- Arithmetic
expr.eval("1 + 2 * 3")           -- 7
expr.eval("10 / 2 - 1")          -- 4
expr.eval("10 % 3")              -- 1

-- Comparison
expr.eval("x > 5", {x = 10})     -- true
expr.eval("x == y", {x = 1, y = 1}) -- true

-- Boolean
expr.eval("a && b", {a = true, b = false})  -- false
expr.eval("a || b", {a = true, b = false})  -- true
expr.eval("!a", {a = false})     -- true

-- Ternary
expr.eval("x > 0 ? 'positive' : 'negative'", {x = 5})

-- Functions
expr.eval("max(1, 5, 3)")        -- 5
expr.eval("min(1, 5, 3)")        -- 1
expr.eval("len([1, 2, 3])")      -- 3

-- Arrays
expr.eval("[1, 2, 3][0]")        -- 1

-- String concatenation
expr.eval("'hello' + ' ' + 'world'")
```



## eval_runner Module


Full Lua execution with security controls.

```lua
local runner = require("eval_runner")

local result, err = runner.run({
    source = [[
        local function double(x)
            return x * 2
        end
        return { double = double }
    ]],
    method = "double",
    args = {21}
})
-- result = 42
```



### Configuration


| Parameter | Type | Description |
|-----------|------|-------------|
| `source` | string | Lua source code (required) |
| `method` | string | Function to call in returned table |
| `args` | any[] | Arguments passed to function |
| `modules` | string[] | Allowed builtin modules |
| `imports` | table | Registry entries to import |
| `context` | table | Values available as `ctx` |
| `allow_classes` | string[] | Additional module classes |
| `custom_modules` | table | Custom tables as modules |
| `limits` | table | Execution limits for this run |



### Step Limit


`limits.max_steps` bounds how long one `runner.run` may execute:

```lua
local result, err = runner.run({
    source = user_source,
    method = "main",
    limits = {max_steps = 500}
})
```

A step is one turn of the eval scheduler: the program advances until it yields or finishes, and each resume consumes one step. Pure computation between yields counts as one step no matter how long it runs, so the limit bounds scheduling turns, not CPU time.

When the count exceeds the limit the run stops and returns `errors.INTERNAL` with `eval exceeded maximum step limit`.

`max_steps = 0` means unlimited. Omitting `limits` inherits the host default:

```yaml


# .wippy.yaml

lua:
  eval:
    max_steps: 10000  # default budget for runs without limits.max_steps
                      # 0 = unlimited; a negative value fails boot
```

`limits` applies to `runner.run` only; `runner.compile` accepts no limits. `limits` must be a table containing only `max_steps`, and `max_steps` must be a non-negative integer — anything else returns `errors.INVALID` before the program runs.



### Module Access


Whitelist allowed modules:

```lua
runner.run({
    source = [[
        local json = require("json")
        return json.encode({hello = "world"})
    ]],
    modules = {"json"}
})
```

Modules not in the list cannot be required.



### Registry Imports


Import entries from the registry:

```lua
runner.run({
    source = [[
        local data = ...
        local utils = require("utils")
        return utils.format(data)
    ]],
    imports = {
        utils = "app.lib:utilities"
    },
    args = {{key = "value"}}
})
```



### Privileged Imports


An import can be granted modules the eval'd code itself cannot see. Use the table form with `id` and `modules`:

```lua
runner.run({
    source = [[
        local pricing = require("pricing")
        return pricing.quote(...)
    ]],
    modules = {"json"},
    imports = {
        pricing = { id = "app.lib:pricing", modules = {"funcs"} }
    },
})
```

The `pricing` library executes in its own scoped environment where `funcs` is available; the eval'd source cannot require or reach `funcs` directly. Granting a module to an import requires the caller to hold `eval.module` permission for that module — capabilities cannot be delegated beyond what the caller itself is allowed.



### Custom Modules


Inject custom tables:

```lua
runner.run({
    source = [[
        return sdk.version
    ]],
    custom_modules = {
        sdk = {version = "1.0.0", api_key = "xxx"}
    }
})
```



### Context Values


Pass data accessible as `ctx`:

```lua
runner.run({
    source = [[
        return "Hello, " .. ctx.get("user")
    ]],
    context = {user = "Alice"}
})
```



### Compiling Programs


`runner.compile` validates source and reports its entrypoint and modules without running it:

```lua
local program, err = runner.compile([[
    local function process(x)
        return x * 2
    end
    return { process = process }
]], "process", {modules = {"json"}})

program:method()   -- "process"  (string)
program:modules()  -- {"json"}    (string[])
```

The options table accepts the same `modules` and `imports` fields as `runner.run`, and the same `eval.module` and `eval.import` permission checks apply. The compiled program is informational; execute by calling `runner.run` with the source and method.



### Module Classes


Modules are categorized by capability:

| Class | Description | Default |
|-------|-------------|---------|
| `deterministic` | Pure functions | Allowed |
| `encoding` | Data encoding | Allowed |
| `time` | Time operations | Allowed |
| `nondeterministic` | Random, etc. | Allowed |
| `process` | Spawn, registry | Blocked |
| `storage` | File, database | Blocked |
| `network` | HTTP, sockets | Blocked |



### Enabling Blocked Classes


```lua
runner.run({
    source = [[
        local http = require("http_client")
        return http.get("https://api.example.com")
    ]],
    modules = {"http_client"},
    allow_classes = {"network"}
})
```



### Permission Checks


The system checks permissions for:

- `eval.compile` - Before compilation
- `eval.run` - Before execution
- `eval.module` - For each module in whitelist, and for each module granted to a privileged import
- `eval.import` - For each registry import
- `eval.class` - For each allowed class

Configure in security policies.



## Compile Cache


Compiled programs are cached in an LRU keyed by source, method, modules, and allowed classes — repeated runs of identical code skip recompilation. Imports and context are bound at run time and do not affect the cache key.

```yaml


# .wippy.yaml

lua:
  eval:
    cache_size: 256   # entries; 0 or less disables caching (default: 256)
    cache_ttl: 0      # expiry; 0 = no expiry (default: 0)
```



## Error Handling


```lua
local result, err = runner.run({...})
if err then
    if err:kind() == errors.PERMISSION_DENIED then
        -- Access denied by security policy
    elseif err:kind() == errors.INVALID then
        -- Invalid source or configuration
    elseif err:kind() == errors.INTERNAL then
        -- Execution or compilation error
    end
end
```



### Plugin System


```lua
local plugins = registry.find({meta = {type = "plugin"}})

for _, plugin in ipairs(plugins) do
    local source = plugin:data().source
    runner.run({
        source = source,
        method = "init",
        modules = {"json", "time"},
        context = {config = app_config}
    })
end
```



### Template Evaluation


```lua
local template = "Hello, {{name}}! You have {{count}} messages."
local compiled = expr.compile("name")

-- Fast repeated evaluation
for _, user in ipairs(users) do
    local greeting = compiled:run({name = user.name})
end
```



### User Scripts


```lua
local user_code = request:body()

local result, err = runner.run({
    source = user_code,
    modules = {"json", "text"},  -- Safe modules only
    context = {data = input_data}
})
```



## See Also


- [Expression](lua/dynamic/expression.md) - Expression language reference
- [Exec](lua/dynamic/exec.md) - System command execution
- [Security](lua/security/security.md) - Security policies



## Navigation

Previous: "UUID Generation" (lua/security/uuid)
Next: "Command Execution" (lua/dynamic/exec)
