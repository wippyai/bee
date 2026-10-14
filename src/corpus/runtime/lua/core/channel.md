# "Channels and Coroutines"

_Path: en/lua/core/channel_

> "Go-style channels for inter-coroutine communication. Create buffered or unbuffered channels, send and receive values, and coordinate between…"

## Table of Contents

- Channels and Coroutines

## Content

# Channels and Coroutines

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

Channels exchange values between concurrent tasks. They can be buffered or unbuffered and can be combined with `channel.select` to coordinate multiple operations.

This is an API reference. The basic blocks are isolated snippets; the timeout, fan-in, and non-blocking sections are partial patterns whose named channels and callbacks come from the surrounding application. The worker-pool block is a complete in-process example.

The `channel` and `coroutine` globals are always available. Channels coordinate coroutines within one Lua process; use process messaging, functions, or queues across process boundaries.



## Creating Channels


An unbuffered channel (size 0) requires a sender and receiver to be ready before a transfer completes. A buffered channel allows sends to complete while buffer space is available.

```lua
-- Unbuffered: synchronizes sender and receiver
local sync_ch = channel.new()

-- Buffered: queue up to 10 messages
local work_queue = channel.new(10)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `size` | integer | Buffer capacity (default: 0 for unbuffered) |

**Returns:** `channel`



## Sending Values


Sending blocks until a receiver is ready on an unbuffered channel or until buffer space is available on a buffered channel.

```lua
-- Send work to a worker pool
local tasks = {"task-a", "task-b"}
local jobs = channel.new(100)
for i, task in ipairs(tasks) do
    jobs:send(task)  -- Blocks if buffer full
end
jobs:close()  -- Signal no more work
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `value` | any | Value to send |

**Returns:** `boolean`

Sending to a closed channel raises an error.



## Receiving Values


Receiving blocks until a value is available or the channel is closed.

```lua
-- Worker consuming from job queue
while true do
    local job, ok = jobs:receive()
    if not ok then
        break  -- Channel closed, no more work
    end
    process(job)
end
```

Here, `jobs` is the application-provided queue and `process` is its task-processing callback.

**Returns:** `any, boolean`

- `value, true` — a value was received
- `nil, false` — the channel is closed and empty



## Closing Channels


Closing a channel causes pending senders to receive an error and pending receivers to receive `nil, false`. Closing an already closed channel is a no-op.

```lua
local results = channel.new(10)

-- Producer fills results
for _, item in ipairs(data) do
    results:send(process(item))
end
results:close()  -- Signal completion
```

This isolated producer snippet assumes `data` and the `process` callback are provided by the application.



## Selecting from Multiple Channels


`channel.select` waits on multiple channel operations at the same time. It can coordinate event sources, timeouts, and non-blocking checks.

```lua
local result = channel.select(cases)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `cases` | table | Array of select cases |
| `default` | boolean | If true, returns immediately when no case ready |

**Returns:** `table`

- For a channel case: `{channel, value, ok}` — `channel` is the case's channel, `value` is the received/sent value, `ok` is false for a closed-channel receive.
- For the default branch (when no case is ready and `default = true`): `{default = true, ok = true}`.



### Timeout Pattern


Use `time.after()` to add a timeout to a channel wait.

```lua
local time = require("time")

local result_ch = application_response_channel
local timeout, err = time.after("5s")
if err then
    return nil, err
end

local r = channel.select {
    result_ch:case_receive(),
    timeout:case_receive()
}

if r.channel == timeout then
    return nil, errors.new({ kind = errors.TIMEOUT, message = "Operation timed out" })
end
return r.value
```

This partial pattern assumes the entry lists `time` in `modules:` and the application supplies `application_response_channel`. `time.after` returns one channel on success; invalid or non-positive durations return `nil, error`.



### Fan-in Pattern


Handle values from multiple sources in one loop.

This process-entry pattern uses ambient `process`, while the application supplies the shutdown signal and the two handler functions.

```lua
local events = process.events()
local inbox = process.inbox()
local shutdown = channel.new()

while true do
    local r = channel.select {
        events:case_receive(),
        inbox:case_receive(),
        shutdown:case_receive()
    }

    if r.channel == shutdown then
        break
    elseif r.channel == events then
        handle_event(r.value)
    else
        handle_message(r.value)
    end
end
```



### Non-Blocking Check


Use a default case to check for available data without blocking.

In this isolated pattern, `ch` and the `process` callback come from the application.

```lua
local r = channel.select {
    ch:case_receive(),
    default = true
}

if r.default then
    -- Nothing available, do something else
elseif not r.ok then
    -- The channel is closed
else
    process(r.value)
end
```



## Creating Select Cases


Create send and receive cases for `channel.select`:

```lua
-- Send case - completes when channel can accept value
ch:case_send(value)

-- Receive case - completes when value available
ch:case_receive()
```

Values in the cases table that are not send or receive cases are ignored. Make sure the table contains at least one valid case unless it also has a default branch.



## Worker Pool Pattern


```lua
local items = {1, 2, 3, 4}
local num_workers = 2

local function process_item(item)
    return item * 2
end

local work = channel.new(#items)
local results = channel.new(#items)

-- Spawn workers
for _ = 1, num_workers do
    coroutine.spawn(function()
        while true do
            local item, ok = work:receive()
            if not ok then
                return
            end
            results:send(process_item(item))
        end
    end)
end

-- Feed work
for _, item in ipairs(items) do
    work:send(item)
end
work:close()

-- Collect results
local processed = {}
while #processed < #items do
    local result, ok = results:receive()
    if not ok then break end
    table.insert(processed, result)
end
```

After the loop, `processed` contains `2`, `4`, `6`, and `8`; result order depends on coroutine scheduling. The workers share channels because they are coroutines in the same Lua process.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Send on closed channel | runtime error | no |
| `cases` argument to select is not a table | runtime error | no |



## See Also


- [Process Management](lua/core/process.md) - Process spawning and communication
- [Message Queue](lua/storage/queue.md) - Queue-based messaging
- [Functions](lua/core/funcs.md) - Function invocation



## Navigation

Previous: "Time & Duration" (lua/core/time)
Next: "Process Management" (lua/core/process)
