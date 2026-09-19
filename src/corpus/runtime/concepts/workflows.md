# "Workflows"

_Path: en/concepts/workflows_

> "How Wippy persists long-running workflows, replays execution, receives signals, and recovers from failures."

## Table of Contents

- Workflows

## Content

# Workflows


Workflows persist the state of long-running operations so execution can recover after crashes and restarts. They suit processes such as payments, order fulfillment, and multi-step approvals.



## Why Use Workflows


Functions keep in-flight state in memory, while workflows persist execution state:

| Aspect | Functions | Workflows |
|--------|-----------|-----------|
| State | Call-local | Rebuilt from persisted history |
| Worker crash | In-flight call fails | Replays from recorded history |
| Duration | Seconds to minutes | Hours to months |
| Application failure | Returned to caller | Ends or retries according to provider policy |



## How Workflows Work


Workflow code looks like regular Lua code:

```lua
local funcs = require("funcs")
local time = require("time")

local result, err = funcs.call("app.api:charge_card", payment)
if err then return nil, err end

time.sleep("24h")

local status, err = funcs.call("app.api:check_status", result.id)
if err then return nil, err end

if status == "failed" then
    local _, refund_err = funcs.call("app.api:refund", result.id)
    if refund_err then return nil, refund_err end
end

return status
```

The workflow engine intercepts calls and records their results. After a crash, it replays execution from the recorded history.

Inside a workflow, each `funcs.call()` target runs as a Temporal activity. A
target `function.*` entry must register with a worker through
`meta.temporal.activity.worker`; unregistered entries are not available to the
workflow. A `process.*` activity target additionally needs
`meta.options.default_host` (or the legacy `meta.default_host`) so it is
registered in the function registry used by the Temporal worker. See
[Activities](../temporal/activities.md) for the function activity example and
activity options.

<note>
Workflow authors must still write deterministic code. Wippy limits workflow
modules to those classified as Deterministic or Workflow and supplies
replay-safe implementations for supported operations. <code>funcs.call()</code>
runs a recorded activity, <code>time.sleep()</code> uses a workflow timer,
<code>uuid.v4()</code> records a side effect, and <code>time.now()</code> reads the
workflow's deterministic time reference.
</note>



### Saga Pattern


Compensate on failure:

```lua
local funcs = require("funcs")

local inventory, err = funcs.call("app.inventory:reserve", items)
if err then return nil, err end

local payment, err = funcs.call("app.payments:charge", amount)
if err then
    local _, compensation_err = funcs.call("app.inventory:release", inventory.id)
    return nil, compensation_err or err
end

local shipping, err = funcs.call("app.shipping:create", order)
if err then
    local _, refund_err = funcs.call("app.payments:refund", payment.id)
    local _, release_err = funcs.call("app.inventory:release", inventory.id)
    return nil, refund_err or release_err or err
end

return {inventory = inventory, payment = payment, shipping = shipping}
```



### Waiting for Signals


Wait for external events (approval decisions, webhooks, user actions):

```lua
local funcs = require("funcs")

local _, err = funcs.call("app.approvals:submit", request)
if err then return nil, err end

local inbox = process.inbox()
local msg, open = inbox:receive()  -- blocks until signal arrives
if not open then return nil, errors.new("workflow inbox closed") end

local decision, payload_err = msg:payload():data()
if payload_err then return nil, payload_err end

if decision.approved then
    return funcs.call("app.orders:fulfill", request.order_id)
else
    return funcs.call("app.notifications:send_rejection", request)
end
```



## Choosing a Compute Model


| Use Case | Choose |
|----------|--------|
| HTTP request handling | Functions |
| Data transformation | Functions |
| Background jobs | Processes |
| User session state | Processes |
| Real-time messaging | Processes |
| Payment processing | Workflows |
| Order fulfillment | Workflows |
| Multi-day approvals | Workflows |



## Starting Workflows


Workflows use `process.spawn()` with a workflow host:

```lua
-- Spawn workflow on temporal worker
local pid, err = process.spawn("app.workflows:order_processor", "app:temporal_worker", order_data)
if err then return nil, err end

-- Send signals to workflow
local ok, err = process.send(pid, "update", {status = "approved"})
if err then return nil, err end
return ok
```

The caller uses the same spawn API. The host determines whether the entry runs
on a `temporal.worker` or a `process.host`. Persisted history and replay apply
only to the Temporal-hosted path. A workflow entry run through an ordinary
process host has in-memory process semantics and does not gain Temporal
durability.

<tip>
When a workflow spawns children via <code>process.spawn()</code>, they become child workflows on the same provider, maintaining durability guarantees.
</tip>



## Failure and Supervision


Processes can run as supervised services using `process.service`:

```yaml


# Process definition

- name: session_handler
  kind: process.lua
  source: file://session_handler.lua
  method: main



# Supervised service wrapping the process

- name: session_manager
  kind: process.service
  process: app:session_handler
  host: app:processes
  lifecycle:
    auto_start: true
    restart:
      max_attempts: 10
```

Workflows do not use process supervision trees. The workflow provider manages
persistence and recovery; application-level retries follow the configured
workflow and activity policies.



## Configuration


Workflow definition (spawned dynamically):

```yaml
- name: order_processor
  kind: workflow.lua
  source: file://order_processor.lua
  method: main
  meta:
    temporal:
      workflow:
        worker: app:temporal_worker
  modules:
    - funcs
    - time
```

Every function or process invoked through `funcs.call()` also declares the
activity worker. For example:

```yaml
- name: charge_card
  kind: function.lua
  source: file://charge_card.lua
  method: main
  meta:
    temporal:
      activity:
        worker: app:temporal_worker
```

Workflow provider:

```yaml
- name: temporal_worker
  kind: temporal.worker
  client: app:temporal_client
  task_queue: "orders"
  lifecycle:
    auto_start: true
```

See [Temporal](https://temporal.io) for production workflow infrastructure.



## See Also


- [Functions](concepts/functions.md) — Request-scoped calls
- [Process Model](concepts/process-model.md) — Stateful background work
- [Supervision](guides/supervision.md) — Process restart policies



## Navigation

Previous: "Functions" (concepts/functions)
Next: "Lua Runtime" (lua/overview)
