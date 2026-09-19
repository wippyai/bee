# "Compute Units"

_Path: en/concepts/compute-units_

> "Compare Wippy functions, processes, and workflows by lifetime, state, communication, and failure handling."

## Table of Contents

- Compute Units

## Content

# Compute Units


Wippy provides three ways to run code: functions, processes, and workflows. They share the same underlying machinery but differ in how long they live, where their state goes, and what happens when things fail.



## Functions


Functions run when called and return a result. Treat each call as stateless:
durable or shared state belongs in a database or store. Function pools can
reuse Lua states, so module globals and closure upvalues are worker-local and
are not a reliable cross-call store.

```lua
local funcs = require("funcs")

local result, err = funcs.call("app.math:add", 2, 3)
if err then
    return nil, err
end
```

Functions execute in the caller's context. If the caller is canceled or exits, its running function calls are canceled as well.

<tip>
Use functions for HTTP handlers, data transformations, and anything that should complete quickly and return a result.
</tip>



## Processes


Processes are actors. They maintain state across multiple messages, run independently of whoever started them, and communicate through message passing.

```lua
local pid, err = process.spawn("app.workers:handler", "app:processes")
if err then return nil, err end

local ok, send_err = process.send(pid, "job", {task = "process_data"})
if send_err then return nil, send_err end
return ok
```

After being spawned, a process runs independently of the code that created it. Processes can monitor or link to one another and can participate in supervision trees that restart failed children.

The scheduler multiplexes thousands of processes across a worker pool. Each process yields when waiting for I/O, letting others run.

<tip>
Use processes for background jobs, service daemons, and anything that needs to outlive its creator or maintain state across messages.
</tip>



## Workflows


Workflows are for durable operations that must recover from interruptions. A
workflow provider such as Temporal records execution history and replays it to
rebuild state after crashes, restarts, or infrastructure changes.

```lua
-- The provider records this workflow so a worker restart can replay it.
local pid, err = process.spawn("app.orders:process", "app:temporal_worker", order_id)
if err then return nil, err end
return pid
```

Durability adds latency because workflow operations are recorded. Use workflows when recovery is more important than the lower latency of functions or processes, such as for multi-step business processes and long-running orchestration.

<note>
Wippy records supported workflow operations so they produce the same results during replay. Workflow code uses the same Lua syntax as other compute units.
</note>



## How They Compare


| | Functions | Processes | Workflows |
|---|---|---|---|
| **State** | Call-local; do not depend on worker reuse | In memory | Rebuilt from persisted history |
| **Lifetime** | Single call | Until exit or crash | Persists across restarts |
| **Communication** | Return value + messages | Message passing | Activity calls + messages |
| **Failure handling** | Caller handles | Supervision trees | Provider recovery; retries follow policy |
| **Latency** | Lowest | Low | Higher |



## Same Code, Different Behavior


Many modules adapt to their context automatically. For example, `time.sleep()`
yields in both functions and processes so other work can run; in a workflow,
the provider also records the timer so replay does not start a second timer.



## Navigation

Previous: "Publishing Modules" (guides/publishing)
Next: "Application Architecture" (concepts/architecture)
