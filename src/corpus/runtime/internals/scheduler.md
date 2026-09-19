# "Scheduler"

_Path: en/internals/scheduler_

> "How Wippy schedules process work, routes events, manages worker queues, and shuts processes down."

## Table of Contents

- Scheduler

## Content

# Scheduler


The scheduler executes processes on workers with local deques, inject queues, a global queue, and work stealing.

This is an implementation reference. Its Go structures and diagrams describe the pinned runtime scheduler, not APIs implemented by application code.



## Process Interface


The scheduler works with any type implementing the `Process` interface:

```go
type Process interface {
    Init(ctx context.Context, method string, input payload.Payloads) error
    Step(events []Event, out *StepOutput) error
    Close()
}
```

| Method | Purpose |
|--------|---------|
| `Init` | Prepare process with entry method name and input arguments |
| `Step` | Advance state machine with incoming events, write yields to output |
| `Close` | Release resources |

The `method` parameter in `Init` specifies which entry point to invoke. A process instance can expose multiple entry points, and the caller selects which one to execute.

The scheduler calls `Step()` repeatedly, passing events (yield completions, messages) and collecting yields (commands to dispatch). The process writes its status and any yields to the `StepOutput` buffer.

```go
type Event struct {
    Type  EventType  // EventYieldComplete or EventMessage
    Tag   uint64     // Correlation tag for yield completions
    Data  any        // Result data or message payload
    Error error      // Error if yield failed
}
```



## Structure


The scheduler spawns `GOMAXPROCS` workers by default. Each worker has a local deque for cache-friendly LIFO access and a per-worker MPSC inject queue for requeued work that has affinity to that worker, including yield completions and message wakes. A global FIFO queue handles new submissions and affinity-less re-queues. Processes are tracked by PID for message routing.



## Work Finding


```mermaid
flowchart TD
    W[Worker needs work] --> L{Local deque?}
    L -->|has items| LP[Pop from bottom LIFO]
    L -->|empty| I{Inject queue?}
    I -->|has items| IP[Pop + drain up to 16 to local]
    I -->|empty| G{Global queue?}
    G -->|has items| GP[Pop + batch transfer up to 16]
    G -->|empty| S[Scan other workers from rotating start]
    S --> SH[Steal up to half, capped at 32]
```

Workers check sources in priority order:

| Priority | Source | Pattern |
|----------|--------|---------|
| 1 | Local deque | LIFO pop, lock-free, cache-friendly |
| 2 | Inject queue | MPSC pop of affine requeues/events, drain up to 16 to local |
| 3 | Global queue | FIFO pop with batch transfer |
| 4 | Other workers | Scan from a rotating start index and steal up to half, capped at 32 items per attempt |

When popping from the inject or global queue, workers take one item and move up to 16 more to their local deque.



## Chase-Lev Deque


Each worker owns a Chase-Lev work-stealing deque:

```go
type Deque struct {
    buffer atomic.Pointer[dequeBuffer]
    top    atomic.Int64  // Thieves steal from here (CAS)
    bottom atomic.Int64  // Owner pushes/pops here
}
```

The owner pushes and pops from the bottom (LIFO) without a mutex; popping the
last item uses CAS to coordinate with thieves. Thieves steal from the top (FIFO)
using CAS. This gives the owner cache-friendly access to recently-pushed items
while distributing older work to stealers.

`StealHalfInto` takes up to half the available items in one CAS operation,
limited by the destination buffer. Worker steal attempts use a 32-item buffer.



## Adaptive Spinning


Before blocking on the condition variable, workers spin adaptively:

| Spin Count | Action |
|------------|--------|
| < 4 | Tight loop |
| 4-15 | Yield thread (`runtime.Gosched`) |
| >= 16 | Block on condition variable |



## Process States


```mermaid
stateDiagram-v2
    [*] --> Ready: Submit
    Ready --> Running: CAS by worker
    Running --> Complete: done
    Running --> Blocked: yields commands
    Running --> Idle: waiting for messages
    Blocked --> Ready: CompleteYield
    Idle --> Ready: Send arrives
```

| State | Description |
|-------|-------------|
| Ready | Queued for execution |
| Running | Worker is executing Step() |
| Blocked | Waiting for yield completion |
| Idle | Waiting for messages |
| Complete | Execution finished |

A wakeup flag handles races: if a handler calls `CompleteYield` while the worker still owns the process (Running), it sets the flag. The worker checks the flag after dispatching and re-queues if set.



## Event Queue


Each process has an MPSC (multi-producer, single-consumer) event queue:

- **Producers**: Command handlers (`CompleteYield`), message senders (`Send`)
- **Consumer**: Worker drains events in `Step()`

A generation counter guards the queue. Every producer binds to the generation it observed; `Reset` bumps it, so a sender left over from a previous execution cannot push into a reused queue.

Ordinary event traffic is unbounded. Accounting is opt-in per message: a message that carries `MaxItems` or `MaxBytes` is admitted against a per-topic budget, and the tightest limit seen for a topic wins. A message holds its reservation until the consuming process releases it, and terminals never consume backlog capacity.

When a topic's budget is exhausted, the queue appends one synthetic message in the overflowing message's place, carrying `message queue limit exceeded` followed by a terminal payload. Further traffic on that topic is discarded until the queue is reset, so a bounded subscription ends with an error terminal rather than growing without bound.



## Message Routing


The scheduler implements `relay.Receiver` to route messages to processes. `Send` delegates to `SendContext` with a background context; `SendContext` checks cancellation before the target lookup and before admission, because admission itself is non-blocking and irreversible once it succeeds.

Both look up the target PID in the `byPID` map and push the package onto the process queue under the processor's current generation. Admission is three-way:

| Result | Meaning | Package ownership |
|--------|---------|-------------------|
| Accepted | The queue took the package | Queue, released by the scheduler after processing |
| Dropped | A per-topic budget overflowed and the queue retained nothing but its own overflow terminal | Caller, released immediately |
| Rejected | The queue is closed or the generation is stale | Caller; `SendContext` returns `ErrProcessClosed` |

An accepted or dropped push then wakes the process if it is idle or blocked. It re-queues via injectOrGlobal, which pushes to the last worker's per-worker inject queue when the process has a known worker affinity, and falls back to the global queue otherwise.



## Shutdown


On shutdown, the scheduler sends cancel events to all tracked processes and waits for them to complete or timeout. Workers exit once no work remains.



## See Also


- [Command Dispatch](internals/dispatch.md) - How yields reach handlers
- [Process Model](concepts/process-model.md) - High-level concepts



## Navigation

Previous: "Registry Internals" (internals/registry)
Next: "Command Dispatch" (internals/dispatch)
