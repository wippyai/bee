# "Lua Runtime"

_Path: en/lua/overview_

> "How Lua code runs in Wippy processes, communicates through channels, loads modules, and handles errors."

## Table of Contents

- Lua Runtime

## Content

# Lua Runtime


Lua is Wippy's primary runtime for I/O-bound work and business logic. Code runs in isolated processes that communicate through message passing rather than shared memory.

This page is a conceptual overview. Its code blocks are isolated reference snippets; names such as `inbox`, `events`, and `handle_message` stand for values or callbacks supplied by the surrounding application.

For the design tradeoffs behind Lua and its relationship to WebAssembly, see [Why Wippy Uses Lua](why-lua.md).



## Processes


Lua code runs inside **processes**: isolated execution contexts managed by the scheduler. Each process:

- has its own memory space;
- yields during blocking operations such as I/O and channel access;
- can be monitored and supervised; and
- can run alongside thousands of other processes on one machine.

```lua
local pid, err = process.spawn("app.workers:handler", "app:processes")
if err then
    return nil, err
end

local sent, send_err = process.send(pid, "task", {data = "work"})
if send_err then
    return nil, send_err
end
```

Executable Lua entries receive `process` as an ambient global. It can also be loaded with `require("process")` without adding it to the entry's `modules` list. See [Process Management](lua/core/process.md) for spawning, linking, and supervision.



## Channels


Channels provide communication between concurrent tasks:

```lua
local sync_ch = channel.new()   -- unbuffered
local buffered = channel.new(10)

buffered:send("work")           -- completes while buffer space is available
local val, ok = buffered:receive()  -- val is "work" and ok is true
```

See [Channels](lua/core/channel.md) for select and patterns.



## Coroutines


Within a process, use lightweight coroutines for concurrent work:

```lua
coroutine.spawn(function()
    local data = fetch_data()
    ch:send(data)
end)

do_other_work()  -- continues immediately
```

The scheduler manages spawned coroutines, so callers do not manually yield or resume them.



## Select


Use `channel.select` to wait for multiple event sources:

```lua
local r = channel.select {
    inbox:case_receive(),
    events:case_receive(),
    timeout:case_receive()
}

if r.channel == timeout then
    -- timed out
elseif r.channel == events then
    handle_event(r.value)
else
    handle_message(r.value)
end
```



## Globals


The following globals are available without `require` and do not need to be listed in `modules:`:

- `channel` - Go-style channels
- `payload` - the entry's input payload
- `process` - process spawning, messaging, monitoring, and lifecycle operations
- `print`, `subscribe`, `unsubscribe` - logging and pub/sub
- `os`, `table`, `math`, `string`, `coroutine`, `errors` - standard libraries



## Modules


Built-in runtime modules that are not ambient are loaded with `require()` and must appear in the entry's `modules:` allowlist. Executable entries receive `process` as an ambient global; `require("process")` is also allowed and does not require a `modules:` declaration.

```lua
local process = require("process")
local json = require("json")
local sql = require("sql")
local http = require("http_client")
```

Available modules depend on entry configuration. See [Entry Definitions](lua/entries.md).

Registry libraries use the same `require("alias")` syntax but are declared separately in the entry's `imports:` map.



## Language and Library Support


Wippy uses Lua 5.3 syntax with a [gradual type system](lua/types.md) inspired by Luau. Types are first-class runtime values that can be used for validation, passed as arguments, and inspected at runtime.

External Lua libraries (LuaRocks, etc.) are not supported. The runtime provides its own module system with built-in extensions for I/O, networking, and system integration.

For custom extensions, see [Modules](internals/modules.md) in the internals documentation.



## Error Handling


Functions commonly return `result, error` pairs:

```lua
local data, err = json.decode(input)
if err then
    return nil, errors.wrap(err, "decode failed")
end
```

This snippet assumes `json` is enabled in the entry's `modules` list and `input` contains the string to decode. See [Error Handling](lua/core/errors.md) for patterns.



## What's Next


- [Entry Definitions](lua/entries.md) - Configure entry points
- [Channels](lua/core/channel.md) - Channel patterns
- [Process Management](lua/core/process.md) - Spawning and supervision
- [Functions](lua/core/funcs.md) - Cross-process calls



## Navigation

Previous: "Workflows" (concepts/workflows)
Next: "Why Wippy Uses Lua" (lua/why-lua)
