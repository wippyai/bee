# "Channels and Concurrency Primer"

_Path: en/tutorials/channels_

> "Review channel operations and coroutine coordination patterns."

## Table of Contents

- Channels and Concurrency Primer

## Content

# Channels and Concurrency Primer


This page introduces channels for coordinating coroutines within a process. The examples cover buffering, selection, producer-consumer flows, fan-out, fan-in, and channel closure.

**Classification:** Reference/API primer. The snippets are independent examples,
not a standalone application.



## Context and Dependencies


Run these snippets inside an exported function of an executable Lua entry such as
`process.lua`. The `channel` and `coroutine` APIs are ambient globals in that
execution context; they do not need `require()` calls or `modules` declarations.
Each snippet creates its own channels and should be evaluated separately.

This page is a primer: each snippet shows one API in isolation. Paste them into the `main` function of a `process.lua` entry to run them, as set up in the [CLI Applications](tutorials/cli.md) tutorial.



## Creating Channels


Channels pass values between coroutines. Create one with `channel.new(capacity)`:

```lua
local ch = channel.new(1)  -- buffered channel, capacity 1
```



### Buffered Channels


A send to a buffered channel blocks only when its buffer is full:

```lua
local ch = channel.new(3)  -- buffer holds 3 items

-- Send without blocking
ch:send(1)
ch:send(2)
ch:send(3)

-- Receive in FIFO order
local v1, ok1 = ch:receive()  -- 1, true
local v2, ok2 = ch:receive()  -- 2, true
local v3, ok3 = ch:receive()  -- 3, true
```



### Unbuffered Channels


Unbuffered channels (capacity 0) synchronize sender and receiver:

```lua
local ch = channel.new(0)  -- unbuffered
local done = channel.new(1)

coroutine.spawn(function()
    ch:send("from spawn")  -- blocks until receiver ready
    done:send(true)
end)

local val = ch:receive()  -- receives "from spawn"
local completed = done:receive()
```



## Channel Select


`channel.select` waits on multiple channel operations and returns the first one that is ready:

```lua
local ch1 = channel.new(1)
local ch2 = channel.new(1)

ch1:send("ch1_value")

local result = channel.select{
    ch1:case_receive(),
    ch2:case_receive()
}

-- result is a table with: channel, value, ok
result.channel == ch1  -- true
result.value           -- "ch1_value"
result.ok              -- true
```



### Select with Send


Use `case_send` to offer a send inside a select. The case is chosen once the channel can accept the value:

```lua
local ch = channel.new(1)

local result = channel.select{
    ch:case_send("sent"),
    default = true
}

if not result.default then
    result.ok  -- true (send succeeded)
end

local v = ch:receive()  -- "sent"
```

Select blocks until one of its cases is ready. Add `default = true` to the case table to return immediately instead, with `result.default` set to true when nothing was ready:

```lua
local full = channel.new(1)
full:send("first")

local result = channel.select{
    full:case_send("second"),
    default = true
}

result.default  -- true (buffer full, nothing sent)
```



## Producer-Consumer Pattern


Single producer, single consumer:

```lua
local ch = channel.new(5)
local done = channel.new(1)
local consumed = 0

-- Consumer
coroutine.spawn(function()
    while true do
        local v, ok = ch:receive()
        if not ok then break end
        consumed = consumed + 1
    end
    done:send(consumed)
end)

-- Producer
for i = 1, 10 do
    ch:send(i)
end
ch:close()

local total = done:receive()  -- 10
```



### Ping-Pong Pattern


Synchronize two coroutines:

```lua
local ping = channel.new(0)
local pong = channel.new(0)
local rounds_done = channel.new(1)

coroutine.spawn(function()
    for i = 1, 5 do
        ping:receive()
        pong:send("pong")
    end
    rounds_done:send(true)
end)

for i = 1, 5 do
    ping:send("ping")
    pong:receive()
end

local completed = rounds_done:receive()
```



## Fan-Out Pattern


One producer, multiple consumers:

```lua
local work = channel.new(10)
local results = channel.new(10)

-- Spawn 3 workers
for w = 1, 3 do
    coroutine.spawn(function()
        while true do
            local job, ok = work:receive()
            if not ok then break end
            results:send(job * 2)
        end
    end)
end

-- Send work
for i = 1, 6 do
    work:send(i)
end
work:close()

-- Collect results
local sum = 0
for i = 1, 6 do
    local r = results:receive()
    sum = sum + r
end
-- sum = (1+2+3+4+5+6)*2 = 42
```



## Fan-In Pattern


Multiple producers, single consumer:

```lua
local output = channel.new(10)
local producer_count = 4
local items_per_producer = 5

-- Spawn producers
for p = 1, producer_count do
    local producer_id = p
    coroutine.spawn(function()
        for i = 1, items_per_producer do
            output:send({producer = producer_id, item = i})
        end
    end)
end

-- Collect all messages
local received = {}
for i = 1, producer_count * items_per_producer do
    local msg = output:receive()
    table.insert(received, msg)
end

-- Verify all producers sent their items
local counts = {}
for _, msg in ipairs(received) do
    counts[msg.producer] = (counts[msg.producer] or 0) + 1
end
```



## Closing Channels


Close channels to signal completion. Receivers get `ok = false` when channel is closed and empty:

```lua
local ch = channel.new(5)
local done = channel.new(1)

coroutine.spawn(function()
    local count = 0
    while true do
        local v, ok = ch:receive()
        if not ok then break end  -- channel closed
        count = count + 1
    end
    done:send(count)
end)

for i = 1, 10 do
    ch:send(i)
end
ch:close()  -- signal no more values

local total = done:receive()
```



## Channel Methods


Channel operations:

- `channel.new(capacity)` — Create a channel with the specified buffer size
- `ch:send(value)` — Send a value, blocking if the buffer is full; sending to a closed channel raises an error
- `ch:receive()` — Receive a value and return `value, ok`
- `ch:close()` — Close the channel; closing it again raises an error
- `ch:case_send(value)` — Create a send case for `select`
- `ch:case_receive()` — Create a receive case for `select`
- `channel.select{cases...}` — Wait on multiple operations and return `channel`, `value`, and `ok`
- `channel.select{cases..., default = true}` — Return `{default = true, ok = true}` immediately when no case is ready



## Next Steps


- [Channel Module Reference](lua/core/channel.md) — Channel API documentation
- [Processes](tutorials/processes.md) — Inter-process communication



## Navigation

Previous: "Echo Service" (tutorials/echo-service)
Next: "Processes and Messaging Primer" (tutorials/processes)
