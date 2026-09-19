# "Queue"

_Path: en/system/queue_

> "Configure memory, AMQP, or SQS queue drivers, logical queues, consumers, acknowledgments, and publishing."

## Table of Contents

- Queue

## Content

# Queue


The queue system connects asynchronous message publishers, drivers, queues, consumers, and handler functions.

This page is a configuration and behavior reference. YAML fences are fragments for an existing entry list unless they show a complete document; external-driver examples assume the broker or AWS-compatible service already exists.



## Architecture


```mermaid
flowchart LR
    P[Publisher] --> D[Driver]
    D --> Q[Queue]
    Q --> C[Consumer]
    C --> W[Worker Pool]
    W --> F[Function]
```

- **Driver** — Backend implementation (memory, AMQP, or SQS)
- **Queue** — Logical queue bound to a driver
- **Consumer** — Connects a queue to a handler with concurrency settings
- **Worker pool** — Concurrent message processors

Multiple queues can share a driver. Multiple consumers can process from the same queue.



## Entry Kinds


| Kind | Description |
|------|-------------|
| `queue.driver.memory` | In-memory queue driver |
| `queue.driver.amqp` | AMQP (RabbitMQ) driver |
| `queue.driver.sqs` | AWS SQS driver (also LocalStack, ElasticMQ) |
| `queue.queue` | Queue declaration with driver reference |
| `queue.consumer` | Consumer that processes messages |



### Memory Driver


The in-process driver is intended for development and single-node deployments and has no external dependencies.

```yaml
- name: memory_driver
  kind: queue.driver.memory
  lifecycle:
    auto_start: true
```



### AMQP Driver


For RabbitMQ and AMQP 0-9-1 compatible brokers.

```yaml
- name: amqp_driver
  kind: queue.driver.amqp
  url: "amqp://guest:guest@localhost:5672/"
  vhost: "/"
  connection_name: "wippy-service"
  heartbeat: "10s"
  connection_timeout: "30s"
  reconnect_delay: "1s"
  reconnect_max_delay: "30s"
  default_message_ttl: "1h"
  default_queue_expiry: "24h"
  prefetch_count: 10
  lifecycle:
    auto_start: true
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `url` | string | `amqp://guest:guest@localhost:5672/` | Broker URL |
| `vhost` | string | - | Virtual host override |
| `connection_name` | string | - | Identifier shown in broker UI |
| `auth_mechanism` | string | `PLAIN` | `PLAIN`, `EXTERNAL` (mTLS), or `AMQPLAIN` |
| `heartbeat` | duration | - | Keep-alive interval |
| `connection_timeout` | duration | - | Dial timeout |
| `reconnect_delay` | duration | `1s` | Initial reconnect backoff |
| `reconnect_max_delay` | duration | `30s` | Max reconnect backoff |
| `default_message_ttl` | duration | - | Per-message expiration used when a publisher does not set one |
| `default_queue_ttl` | duration | - | Default queue-level message TTL (`x-message-ttl`) |
| `default_queue_expiry` | duration | - | Default unused-queue expiration (`x-expires`) |
| `prefetch_count` | int | - | Channel-level prefetch ceiling |
| `frame_size` | int | - | AMQP frame size limit |
| `channel_max` | int | - | Max channels per connection |
| `tls` | object | - | TLS settings (see below) |

Configure TLS under `tls`:

```yaml
  tls:
    enabled: true
    server_name: "rabbit.example.com"
    cert: ${env:app.env:amqp_cert}
    key:  ${env:app.env:amqp_key}
    ca:   ${env:app.env:amqp_ca}
    insecure_skip_verify: false
```

`cert`/`key`/`ca` carry PEM content — inline, via `file://`, or via a `${env:NAME}` placeholder resolved through the [env registry](system/env.md). `insecure_skip_verify` disables certificate verification (development only). Legacy `cert_env`/`key_env`/`ca_env` directives also read the environment registry, but preserve an inline or zero value when the lookup is missing or empty; modern placeholders without defaults fail on missing variables. The legacy directives are deprecated.



### SQS Driver


For AWS SQS and SQS-compatible endpoints (LocalStack, ElasticMQ). Credentials, region, and other AWS SDK settings come from a shared `config.aws` resource.

```yaml
- name: aws_config
  kind: config.aws
  region: us-east-1
  access_key_id: ${env:app:AWS_ACCESS_KEY_ID}
  secret_access_key: ${env:app:AWS_SECRET_ACCESS_KEY}

- name: sqs_driver
  kind: queue.driver.sqs
  config: app:aws_config
  endpoint: "http://localhost:9324"
  message_retention_period: 86400
  default_delay_seconds: 0
  lifecycle:
    auto_start: true
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `config` | Registry ID | required | `config.aws` resource providing region and credentials |
| `endpoint` | string | - | Custom endpoint URL (LocalStack, ElasticMQ); omit for real AWS |
| `message_retention_period` | int | - | Queue-level retention in seconds (60–1209600), set as a queue attribute on create. Omit to leave the AWS default of 345600 (4 days). |
| `default_delay_seconds` | int | `0` | Default delivery delay applied on CreateQueue (0–900) |
| `disable_message_checksum_validation` | bool | `false` | Disable SQS message checksum checks on send/receive |
| `use_fips` | bool | `false` | Use FIPS-compliant endpoints |
| `use_dual_stack` | bool | `false` | Use dual-stack (IPv4 + IPv6) endpoints |

Queues are auto-created by the driver on first use. Use SQS-prefixed headers to address SQS-specific fields on publish: `sqs.delay_seconds`, `sqs.message_group_id`, and `sqs.message_deduplication_id` map to typed SQS message fields. All other headers (neutral keys like `correlation_id` and `content_type`, plus any `sqs.message_attributes.*` keys) are carried verbatim as SQS message attributes.



## Queue Configuration


```yaml
- name: tasks
  kind: queue.queue
  driver: app.queue:memory_driver
  codec: json/plain
  queue_name: "app_tasks"
  driver_options:
    memory:
      max_length: 500
  dead_letter:
    queue: app.queue:tasks_dlq
    max_attempts: 5
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `driver` | Registry ID | Yes | Queue driver |
| `codec` | string | No | Wire encoding for message bodies. Defaults to `json/plain` (see [Codecs](#codecs)) |
| `queue_name` | string | No | External queue name (defaults to entry name) |
| `driver_options` | object | No | Per-driver sub-bag, keyed by driver kind |
| `dead_letter.queue` | Registry ID | No | Queue ID for failed messages (accepted but not yet enforced by any built-in driver) |
| `dead_letter.max_attempts` | int | No | Attempts before routing to DLQ (accepted but not yet enforced by any built-in driver) |



### Driver Options


Keys under `driver_options` are scoped by driver name. A driver reads only its own sub-bag — other keys are dormant, which lets a single queue entry declare settings for multiple drivers if needed.

**memory:**

| Key | Description |
|-----|-------------|
| `max_length` | Bounded buffer size (0 or unset = default 1000) |

**amqp:**

| Key | Description |
|-----|-------------|
| `durable` | Survive broker restart |
| `auto_delete` | Delete when last consumer detaches |
| `message_ttl` | Per-queue message TTL override |
| `queue_expiry` | Unused-queue expiration |
| `max_length` | Max messages retained |



### Codecs


The `codec` selects how a message body is serialized before it is handed to the broker. It is a payload format string and defaults to `json/plain`:

| Codec | Format |
|-------|--------|
| `json/plain` | JSON (default) |
| `application/msgpack` | MessagePack |

The AMQP driver sets a matching `content-type` (`application/json` or `application/msgpack`) on published messages. An unknown codec fails when the queue is declared, not at publish time.



## Consumer Configuration


```yaml
- name: task_consumer
  kind: queue.consumer
  queue: app.queue:tasks
  func: app.queue:task_handler
  concurrency: 4
  prefetch: 20
  auto_ack: false
  driver_options:
    amqp:
      consumer_tag: "worker-1"
      exclusive: false
  lifecycle:
    auto_start: true
    requires:
      - app.queue:tasks
```

| Field | Default | Description |
|-------|---------|-------------|
| `queue` | required | Queue registry ID |
| `func` | required | Handler function registry ID |
| `concurrency` | 1 | Parallel worker count |
| `prefetch` | 10 | Shared delivery-buffer size; AMQP also applies it as the channel QoS prefetch count |
| `auto_ack` | false | Backend-specific auto-ack option; for AMQP, `true` asks the broker to acknowledge on delivery |
| `driver_options` | - | Per-driver sub-bag (same structure as queue) |

**amqp consumer options:**

| Key | Description |
|-----|-------------|
| `exclusive` | Single-consumer queue access |
| `no_local` | Reject messages published on the same connection |
| `no_wait` | Don't wait for broker confirmation on subscribe |
| `consumer_tag` | Identifier for this subscription |

<tip>
Consumers respect call context and can be subject to security policies. Configure actor and policies at the lifecycle level. See <a href="./security.md">Security</a>.
</tip>



### Worker Pool


Workers run concurrently:

```
concurrency: 3, prefetch: 10

1. Driver delivers up to 10 messages to the shared buffer
2. 3 workers pull from the buffer and can each hold an active delivery
3. As workers finish, buffer refills
4. Backpressure when all workers busy and buffer full
```



## Handler Function


Consumer handlers receive the decoded message body as the first argument. Use `queue.message()` to access delivery metadata (id, headers).

```lua
local queue = require("queue")
local logger = require("logger")

local function main(body)
    local msg, msg_err = queue.message()
    if msg_err then return nil, msg_err end
    local message_id, id_err = msg:id()
    if id_err then return nil, id_err end
    local correlation_id, header_err = msg:header("correlation_id")
    if header_err then return nil, header_err end

    logger:info("processing", {
        id = message_id,
        correlation_id = correlation_id
    })

    local ok, err = process_task(body)
    if err then
        return nil, err  -- nack: redelivery per driver
    end
    return true          -- ack: remove from queue
end

return { main = main }
```

```yaml
- name: task_handler
  kind: function.lua
  source: file://task_handler.lua
  method: main
  modules:
    - queue
    - logger
```



### Acknowledgment


Unless the handler settles explicitly, the consumer settles from the function invocation result:

| Handler Result | Action |
|----------------|--------|
| Any plain return value (including `false`) | Ack |
| `nil, err` return | Nack (redeliver per driver) |
| Raised error | Nack |

Ordinary return values, including `false`, do not select acknowledgment behavior. Call `msg:ack()` or `msg:nack()` to settle explicitly. Settlement is single-shot: whichever call lands first wins.



### Dead-Letter Routing


Dead-letter routing is not yet implemented. The `dead_letter` block (see [Queue Configuration](#queue-configuration)) is accepted in config, but no built-in driver currently counts attempts, routes nacked messages to the configured DLQ, or sets `x_dead_letter_*` headers. A nacked message is redelivered per the driver's own policy. The `x_*` header namespace is reserved for future DLQ bookkeeping, so publishers should avoid setting `x_*` headers.



## Publishing Messages


From Lua code:

```lua
local queue = require("queue")

local published, publish_err = queue.publish("app.queue:tasks", {
    id = "task-123",
    action = "process",
    data = payload
})
if publish_err then return nil, publish_err end
return published
```

See [Queue Module](lua/storage/queue.md) for the Lua publishing and message API.



## Graceful Shutdown


On consumer stop:

1. Stop accepting new deliveries
2. Cancel worker contexts
3. Wait for in-flight messages (with timeout)
4. Return error if workers don't finish in time



## See Also


- [Queue Module](lua/storage/queue.md) - Lua API reference
- [Queue Consumers Guide](guides/queue-consumers.md) - Consumer patterns and worker pools
- [Supervision](guides/supervision.md) - Consumer lifecycle management



## Navigation

Previous: "Store (Key-Value)" (system/store)
Next: "Network Overlays" (system/network)
