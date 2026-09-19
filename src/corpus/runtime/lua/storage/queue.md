# "Message Queue"

_Path: en/lua/storage/queue_

> "Publish and consume messages from distributed queues. Supports multiple backends including RabbitMQ and other AMQP-compatible brokers."

## Table of Contents

- Message Queue

## Content

# Message Queue

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>
<secondary-label ref="permissions"/>

The `queue` module publishes messages and processes deliveries from configured distributed queues, including RabbitMQ and other AMQP-compatible brokers.

This page is an API reference. Publishing snippets assume the queue entries and permissions already exist. The consumer section is a partial recipe for a handler invoked by `queue.consumer`; it is not a standalone queue deployment.

For queue configuration, see [Queue](system/queue.md).



## Loading


```lua
local queue = require("queue")
```



## Publishing Messages


Publish a message to a queue by ID:

```lua
local ok, err = queue.publish("app:tasks", {
    action = "send_email",
    user_id = 456,
    template = "welcome"
})
if err then
    return nil, err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `queue_id` | string | Queue identifier (format: "namespace:name") |
| `data` | any | Message data (tables, strings, numbers, booleans) |
| `headers` | table | Optional message headers |

**Returns:** `boolean, error`



### Message Headers


Headers carry routing, priority, and tracing metadata. Keys must be strings, and publisher values may be strings, integers, numbers, or booleans:

```lua
local ok, err = queue.publish("app:notifications", {
    type = "order_shipped",
    order_id = order.id
}, {
    priority = 5,
    correlation_id = request_id
})
if err then return nil, err end
```

Consumers receive every header value as a string. The `x_original_queue`, `x_dead_letter_reason`, `x_dead_letter_time`, and `attempts` keys are reserved for delivery and dead-letter bookkeeping and must not be set by publishers.



## Accessing Delivery Context


Access the current delivery from within a queue consumer:

```lua
local msg, err = queue.message()
if err then
    return nil, err
end

local msg_id, id_err = msg:id()
if id_err then return nil, id_err end
local priority, header_err = msg:header("priority")
if header_err then return nil, header_err end
local all_headers, headers_err = msg:headers()
if headers_err then return nil, headers_err end
```

**Returns:** `Message, error`

This function is available only while a queue consumer is processing a message.



## Message Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `id()` | `string, error` | Unique message identifier |
| `header(key)` | `string, error` | Single header value as a string (nil if missing) |
| `headers()` | `table, error` | All message headers |
| `ack()` | `boolean, error` | Acknowledge processing (single-shot) |
| `nack()` | `boolean, error` | Signal failure for redelivery or dead-letter (single-shot) |

The runtime auto-acks on handler success and auto-nacks on handler error. Call `ack`/`nack` only to settle early. Settlement is single-shot, and a `Message` is invalid after its consumer handler returns.



## Queue Info


```lua
local stats, err = queue.info("app:tasks")
if err then return nil, err end
-- stats may contain: message_count, consumer_count, ready (driver-dependent)
```

**Returns:** `table, error`



## Consumer Pattern


A `queue.consumer` entry binds a queue to the handler referenced by `func`. The handler receives the message payload directly:

```yaml
entries:
  - kind: queue.consumer
    name: email_worker
    queue: app:emails
    func: app:email_handler
```

This fragment assumes `app:emails` and the `app:email_handler` function entry already exist. The function source below assumes the application supplies `deliver_email(payload)` and grants any permissions it needs.

```lua
local queue = require("queue")
local logger = require("logger")

local function main(payload)
    local msg, msg_err = queue.message()
    if msg_err then return nil, msg_err end

    local message_id, id_err = msg:id()
    if id_err then return nil, id_err end

    logger:info("Processing", {
        message_id = message_id,
        to = payload.to
    })

    local ok, send_err = deliver_email(payload)
    if send_err then return nil, send_err end
    return ok
end

return {main = main}
```

Returning an invocation error causes the consumer to nack the unsettled delivery. Redelivery then follows the selected driver's behavior; the built-in dead-letter configuration is not enforced in this release.



## Permissions


Security policy evaluation applies to queue operations.

| Action | Resource | Description |
|--------|----------|-------------|
| `queue.publish` | - | General permission to publish messages |
| `queue.publish.queue` | Queue ID | Publish to specific queue |

The runtime checks the general permission first and the queue-specific permission second.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Queue ID empty | `errors.INVALID` | no |
| Message argument missing or an empty table | `errors.INVALID` | no |
| No delivery context | `errors.INVALID` | no |
| Message released or already settled | `errors.INVALID` | no |
| Publish not allowed | `errors.INVALID` | no |
| Publish failed | `errors.INTERNAL` | no |
| Queue or driver not found for `info` | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Queue Configuration](system/queue.md) - Queue drivers and entry definitions
- [Queue Consumers Guide](guides/queue-consumers.md) - Consumer patterns and worker pools
- [Process Management](lua/core/process.md) - Process spawning and communication
- [Channels](lua/core/channel.md) - Inter-process communication patterns
- [Functions](lua/core/funcs.md) - Async function invocation



## Navigation

Previous: "Cloud Storage" (lua/storage/cloud)
Next: "CDC" (lua/storage/cdc)
