# "Process Host"

_Path: en/system/process-host_

> "Process hosts manage Lua and WebAssembly process execution using a work-stealing scheduler."

## Table of Contents

- Process Host

## Content

# Process Host


A `process.host` runs Lua and WebAssembly processes on a work-stealing scheduler. This page is a configuration and lifecycle reference; the YAML block is an entry fragment.

<note>
Each host schedules processes independently. Load is not distributed between hosts automatically.
</note>



## Entry Kind


| Kind | Description |
|------|-------------|
| `process.host` | Process execution host with scheduler |



## Configuration


```yaml
- name: main_host
  kind: process.host
  host:
    workers: 8
    queue_size: 1024
    local_queue_size: 256
  lifecycle:
    auto_start: true
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `workers` | int | NumCPU | Worker goroutines |
| `queue_size` | int | 1024 | Initial global queue capacity |
| `local_queue_size` | int | 256 | Initial per-worker local deque capacity |

Both queues grow when their initial capacity is exhausted. Values must be
positive after defaults are applied. The global queue clamps its effective
initial capacity to at least 16; each local deque rounds its capacity up to a
power of two.



## Lifecycle


A process host is a supervisor-managed service. `lifecycle.auto_start` defaults
to `false`; a host that has not started rejects process spawns. The standard
lifecycle fields also apply, including `requires`, `startup`, `start_timeout`,
`stop_timeout`, `stable_threshold`, `restart`, and `security`.

Stopping a host is terminal for that host instance. The scheduler sends a
cancellation event to each process, waits for them to drain until the stop
context expires, then cancels and closes any remaining processes.

Live updates may resize `host.workers`. Changes to queue sizes or lifecycle
configuration are rejected and require replacing the host. When CPU affinity
manages the worker set, the worker count cannot be changed live either.



## Scheduler


The scheduler uses work-stealing: each worker has a local deque, and idle workers steal from the global queue or other workers. This balances load automatically.

- **Workers** execute processes concurrently.
- **Global queue** holds pending processes when all workers are busy.
- **Local queues** reduce contention by keeping work close to workers.



## Process Types


Process hosts execute entries of these kinds:

| Kind | Description |
|------|-------------|
| `process.lua` | Source-based Lua process |
| `process.lua.bc` | Precompiled Lua bytecode |
| `process.wasm` | WebAssembly process (experimental) |

Processes run independently with their own frame context and communicate via
messages. Security configured on the process entry is applied to that process
frame before execution. Monitors, links, and application supervisors can react
to failure; the process host does not automatically restart every failed
process.



## See Also


- [Process Module](lua/core/process.md) - Spawn and manage processes from Lua
- [WASM Processes](wasm/processes.md) - Configuring `process.wasm` entries
- [Process Model](concepts/process-model.md) - Lifecycle and supervision concepts
- [Supervision](guides/supervision.md) - Building supervision trees



## Navigation

Previous: "Workflows" (temporal/workflows)
Next: "Process Groups" (system/process-groups)
