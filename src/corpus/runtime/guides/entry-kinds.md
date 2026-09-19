# "Entry Kinds Reference"

_Path: en/guides/entry-kinds_

> "Reference for Wippy entry kinds across runtime, storage, networking, security, execution, and lifecycle systems."

## Table of Contents

- Entry Kinds Reference

## Content

# Entry Kinds Reference


This page summarizes the available entry kinds and links to their detailed module and system references.

The YAML and Lua blocks are reference fragments, not one application. Registry IDs,
credentials, data objects, and helpers such as `get_users` or `delete_user` are
illustrative; use the linked module pages for complete return and error contracts.

> Entries reference one another using `namespace:name`. The registry uses these references to resolve dependencies and initialization order.



## See Also


- [Registry](concepts/registry.md) — How entries are stored and resolved
- [Configuration](guides/configuration.md) — YAML configuration format



## Lua Runtime


| Kind | Description |
|------|-------------|
| `function.lua` | Lua function entry point |
| `process.lua` | Long-running Lua process |
| `workflow.lua` | Temporal workflow (deterministic) |
| `library.lua` | Shared Lua library |
| `module.lua` | Lua module surface |
| `function.lua.bc` | Precompiled function bytecode |
| `library.lua.bc` | Precompiled library bytecode |
| `process.lua.bc` | Precompiled process bytecode |
| `workflow.lua.bc` | Precompiled workflow bytecode |

```yaml
- name: handler
  kind: function.lua
  source: file://handler.lua
  method: main
  modules:
    - http
    - json
  imports:
    utils: app.lib:helpers  # Import another entry as module
```

<tip>
Use <code>imports</code> to reference other Lua entries. They become available via <code>require("alias_name")</code> in your code.
</tip>



## HTTP Services


| Kind | Description |
|------|-------------|
| `http.service` | HTTP server (binds port) |
| `http.router` | Route prefix and middleware |
| `http.endpoint` | HTTP endpoint (method + path) |
| `http.static` | Static file serving |

```yaml


# HTTP server

- name: gateway
  kind: http.service
  addr: ":8080"
  lifecycle:
    auto_start: true



# Router with middleware

- name: api
  kind: http.router
  meta:
    server: gateway
  prefix: /api
  middleware:
    - cors
    - ratelimit



# Endpoint

- name: users_list
  kind: http.endpoint
  meta:
    router: app:api
  method: GET
  path: /users
  func: list_handler
```

**Lua API:** See [HTTP Module](lua/http/http.md)

```lua
local http = require("http")
local req = http.request()
local resp = http.response()

resp:set_status(200)
resp:write_json({users = get_users()})
```



## Databases


| Kind | Description |
|------|-------------|
| `db.sql.sqlite` | SQLite database |
| `db.sql.postgres` | PostgreSQL database |
| `db.sql.mysql` | MySQL database |
| `db.cdc.postgres` | Postgres Change Data Capture source (see [CDC](system/cdc.md)) |
| `db.cdc.sqlite` | SQLite Change Data Capture source (see [CDC](system/cdc.md)) |



### SQLite


```yaml
- name: database
  kind: db.sql.sqlite
  file: "./data/app.db"
  lifecycle:
    auto_start: true



# In-memory for testing

- name: testdb
  kind: db.sql.sqlite
  file: ":memory:"
```



### PostgreSQL


```yaml
- name: database
  kind: db.sql.postgres
  host: localhost
  port: 5432
  database: dbname
  username: user
  password: pass
  options:
    sslmode: disable
  pool:
    max_open: 25
    max_idle: 5
    max_lifetime: "30m"
  lifecycle:
    auto_start: true
```



### MySQL


```yaml
- name: database
  kind: db.sql.mysql
  host: localhost
  port: 3306
  database: dbname
  username: user
  password: pass
  options:
    parseTime: "true"
  lifecycle:
    auto_start: true
```

See [Database](system/database.md) for `${env:NAME}` secret references, TLS options, and connection pool tuning. When an env-backed value behind a database entry changes, the pool swaps live — active borrows finish against the old connection settings.

**Lua API:** See [SQL Module](lua/storage/sql.md)

```lua
local sql = require("sql")
local db, err = sql.get("app:database")

local rows, err = db:query("SELECT * FROM users WHERE id = ?", {user_id})
db:execute("INSERT INTO logs (msg) VALUES (?)", {message})
```




## Key-Value Stores


| Kind | Description |
|------|-------------|
| `store.memory` | In-memory key-value store |
| `store.sql` | SQL-backed key-value store |
| `store.kv.raft` | Cluster-replicated, strongly-consistent KV (shared Raft) |
| `store.kv.crdt` | Cluster-replicated, eventually-consistent KV (gossip/CRDT) |

```yaml


# Memory store

- name: cache
  kind: store.memory
  lifecycle:
    auto_start: true



# SQL-backed store

- name: persistent_store
  kind: store.sql
  database: app:database
  table_name: kv_store
  lifecycle:
    auto_start: true



# Cluster-replicated store (requires clustering)

- name: deployments
  kind: store.kv.raft
  namespace: deploy
```

The `store.kv.*` kinds need [clustering](guides/cluster.md) enabled. See [Store](system/store.md#cluster-kv-stores) for the consistency tradeoffs.

**Lua API:** See [Store Module](lua/storage/store.md)

```lua
local store = require("store")
local s, err = store.get("app:cache")

s:set("user:123", user_data, 3600)  -- TTL in seconds
local data = s:get("user:123")
```



## Queues


| Kind | Description |
|------|-------------|
| `queue.driver.memory` | In-memory queue driver |
| `queue.driver.amqp` | AMQP (RabbitMQ) driver |
| `queue.driver.sqs` | AWS SQS driver |
| `queue.queue` | Queue declaration |
| `queue.consumer` | Queue consumer |

```yaml


# Driver

- name: queue_driver
  kind: queue.driver.memory
  lifecycle:
    auto_start: true



# Queue

- name: jobs
  kind: queue.queue
  driver: queue_driver



# Consumer

- name: job_consumer
  kind: queue.consumer
  queue: app:jobs
  func: job_handler
  concurrency: 4
  prefetch: 10
  lifecycle:
    auto_start: true
```

**Lua API:** See [Queue Module](lua/storage/queue.md)

```lua
local queue = require("queue")

-- Publish a message
queue.publish("app:jobs", {task = "process", id = 123})

-- In a consumer handler: the message body is the handler's argument
local function main(data)
    -- access delivery metadata via the current message
    local msg = queue.message()
    local id = msg:id()
    local priority = msg:header("priority")
    msg:ack()
end
```

<note>
The consumer's <code>func</code> is invoked once per message with the message body as its argument. Use <code>queue.message()</code> inside the handler for the delivery's <code>id()</code>, <code>header()</code>/<code>headers()</code>, and <code>ack()</code>/<code>nack()</code>.
</note>



## Process Management


| Kind | Description |
|------|-------------|
| `process.host` | Process execution host |
| `process.service` | Supervised process (wraps process.lua) |
| `terminal.host` | Terminal/CLI host |
| `pg.scope` | Process-group scope (see [Process Groups](system/process-groups.md)) |

```yaml


# Process host (where processes run)

- name: processes
  kind: process.host
  host:
    workers: 32             # Worker goroutines (default: NumCPU)
    queue_size: 1024        # Global queue capacity
    local_queue_size: 256   # Per-worker queue
  lifecycle:
    auto_start: true



# Process definition

- name: worker_process
  kind: process.lua
  source: file://worker.lua
  method: main



# Supervised process service

- name: worker
  kind: process.service
  process: app:worker_process
  host: app:processes
  input: ["arg1", "arg2"]
  lifecycle:
    auto_start: true
    restart:
      max_attempts: 10

- name: terminal
  kind: terminal.host
  lifecycle:
    auto_start: true
```

<tip>
Use <code>process.service</code> when you need a process to run as a supervised service with automatic restart. The <code>process</code> field references a <code>process.lua</code> entry.
</tip>

Updating a live `process.host` entry rescales `host.workers` in place — running processes, PIDs, and queues are preserved. `host.queue_size`, `host.local_queue_size`, and `lifecycle` are fixed at construction: a live update changing them is rejected, as is resizing workers on a host whose workers are affinity-managed.



### Process security


`process.lua` and `process.lua.bc` entries accept a top-level `security:` block. It is part of the entry, so it applies to every spawn of that process, on both `process.host` and `terminal.host`:

```yaml
- name: worker_process
  kind: process.lua
  source: file://worker.lua
  method: main
  security:
    actor:
      id: system.worker
      meta:
        tenant: acme
    policies:
      - app.security:worker_policy
    groups:
      - app.security:background_jobs
```

| Field | Description |
|-------|-------------|
| `actor.id` | Actor identity the process runs as; replaces the inherited actor |
| `actor.meta` | Actor attributes policies evaluate |
| `policies` | Registry IDs (`namespace:name`) of policies merged into the scope |
| `groups` | Registry IDs of policy groups whose policies are merged into the scope |

Resolution happens as the process starts and is atomic: if any listed policy or group cannot be resolved, the spawn fails and no partial context is installed. Omitting `actor` inherits the spawner's actor; omitting both `policies` and `groups` inherits the spawner's scope. `function.lua`, `function.lua.bc`, `process.lua`, and `process.lua.bc` all accept the block.

A command entry can additionally declare `meta.command.security`, which applies only when the entry is launched as a CLI command — see [Command security](guides/cli.md#command-security). It does not affect ordinary spawns.

See [Security](system/security.md).



## Temporal (Workflows)


| Kind | Description |
|------|-------------|
| `temporal.client` | Temporal client connection |
| `temporal.worker` | Temporal worker |

```yaml
- name: temporal_client
  kind: temporal.client
  address: "localhost:7233"
  namespace: "default"
  auth:
    type: none  # none, api_key, mtls
  lifecycle:
    auto_start: true

- name: temporal_worker
  kind: temporal.worker
  client: temporal_client
  task_queue: "main-queue"
  lifecycle:
    auto_start: true
```



## Cloud Storage


| Kind | Description |
|------|-------------|
| `config.aws` | AWS configuration |
| `cloudstorage.s3` | S3 bucket access |

```yaml
- name: aws
  kind: config.aws
  region: "us-east-1"
  access_key_id: ${env:AWS_ACCESS_KEY_ID}
  secret_access_key: ${env:AWS_SECRET_ACCESS_KEY}

- name: uploads
  kind: cloudstorage.s3
  config: app:aws
  bucket: "my-uploads"
  endpoint: ""  # Optional, for S3-compatible services
```

**Lua API:** See [Cloud Storage Module](lua/storage/cloud.md)

```lua
local cloudstorage = require("cloudstorage")
local storage, err = cloudstorage.get("app:uploads")

storage:upload_object("files/doc.pdf", file_content)
local url = storage:presigned_get_url("files/doc.pdf", {expiration = 3600})  -- seconds, default 3600
```

<tip>
Use <code>endpoint</code> to connect to S3-compatible services like MinIO or DigitalOcean Spaces.
</tip>



## File Systems


| Kind | Description |
|------|-------------|
| `fs.directory` | Directory access |
| `fs.embed` | Read-only embedded filesystem |

```yaml
- name: data_dir
  kind: fs.directory
  directory: "./data"
  auto_init: true   # Create if not exists
  mode: "0755"      # Permissions
```

**Lua API:** See [Filesystem Module](lua/storage/filesystem.md)

```lua
local fs = require("fs")
local filesystem, err = fs.get("app:data_dir")

local file = filesystem:open("output.txt", "w")
file:write("Hello, World!")
file:close()
```



## Environment


| Kind | Description |
|------|-------------|
| `env.storage.memory` | In-memory env storage |
| `env.storage.file` | File-based env storage |
| `env.storage.os` | OS environment |
| `env.storage.static` | Read-only static key-value storage |
| `env.storage.router` | Env router (multiple storages) |
| `env.variable` | Environment variable |

```yaml
- name: os_env
  kind: env.storage.os

- name: file_env
  kind: env.storage.file
  file_path: ".env"
  auto_create: true

- name: defaults
  kind: env.storage.static
  values:
    PUBLIC_API_HOST: "https://api.example.com"
    APP_ENV: "production"

- name: app_env
  kind: env.storage.router
  storages:
    - app:os_env
    - app:file_env
    - app:defaults
```

**Lua API:** See [Env Module](lua/system/env.md)

```lua
local env = require("env")

local api_key = env.get("API_KEY")
env.set("CACHE_TTL", "3600")
```

<note>
The router tries storages in order. First match wins for reads; writes go to the first storage in the list.
</note>



## Templates


| Kind | Description |
|------|-------------|
| `template.jet` | Individual Jet template |
| `template.set` | Template set configuration |

```yaml


# Template set with engine configuration

- name: templates
  kind: template.set
  engine:
    development_mode: false
    extensions:
      - ".jet"
      - ".html.jet"



# Individual template

- name: email_template
  kind: template.jet
  source: file://templates/email.jet
  set: app:templates
```

**Lua API:** See [Template Module](lua/text/template.md)

```lua
local templates = require("templates")
local set, err = templates.get("app:templates")

local html = set:render("email", {
    user = "Alice",
    message = "Welcome!"
})
```



## Security


| Kind | Description |
|------|-------------|
| `security.policy` | Security policy with conditions |
| `security.policy.expr` | Expression-based policy |
| `security.token_store` | Token storage |

```yaml


# Condition-based policy

- name: admin_policy
  kind: security.policy
  policy:
    actions: "*"
    resources: "*"
    effect: allow
    conditions:
      - field: "actor.meta.role"
        operator: eq
        value: "admin"



# Expression-based policy

- name: owner_policy
  kind: security.policy.expr
  policy:
    actions: "*"
    resources: "*"
    effect: allow
    expression: 'actor.id == meta.owner_id || actor.meta.role == "admin"'
  groups:
    - operators
```

Policy groups are formed by the policies themselves: a policy lists the group IDs it belongs to under `groups:`, and a group is the set of policies naming it. There is no separate group entry kind. Group IDs are registry IDs — a bare name resolves in the declaring policy's namespace, so `operators` above becomes `app.security:operators` when declared in namespace `app.security`. Entries reference groups by their full `namespace:name`.

**Lua API:** See [Security Module](lua/security/security.md)

```lua
local security = require("security")

-- Check permission before action
if security.can("delete", "users", {user_id = id}) then
    delete_user(id)
end

-- Get current actor
local actor = security.actor()
```

<warning>
Every policy in scope is evaluated. A <code>deny</code> from any matching policy wins over every <code>allow</code>; with no deny, a matching <code>allow</code> grants access. Order does not matter.
</warning>



## Contracts (Dependency Injection)


| Kind | Description |
|------|-------------|
| `contract.definition` | Interface with method specifications |
| `contract.binding` | Maps contract methods to function implementations |

```yaml


# Define the contract interface

- name: greeter
  kind: contract.definition
  methods:
    - name: greet
      description: Returns a greeting message
    - name: greet_with_name
      description: Returns a personalized greeting
      input_schemas:
        - format: "application/schema+json"
          definition: {"type": "string"}
      output_schemas:
        - format: "application/schema+json"
          definition: {"type": "string"}



# Implementation functions

- name: greeter_greet
  kind: function.lua
  source: file://greeter_greet.lua
  method: main

- name: greeter_greet_name
  kind: function.lua
  source: file://greeter_greet_name.lua
  method: main



# Bind contract methods to implementations

- name: greeter_impl
  kind: contract.binding
  contracts:
    - contract: app:greeter
      default: true
      methods:
        greet: app:greeter_greet
        greet_with_name: app:greeter_greet_name
```

Usage from Lua:

```lua
local contract = require("contract")

-- Open binding by ID
local greeter, err = contract.open("app:greeter_impl")

-- Call methods
local result = greeter:greet()
local personalized = greeter:greet_with_name("Alice")

-- Check if instance implements contract
local is_greeter = contract.is(greeter, "app:greeter")
```

**Lua API:** See [Contract Module](lua/core/contract.md)

<tip>
Mark one binding as <code>default: true</code> to use it when opening a contract without specifying a binding ID. A contract may have only one default binding.
</tip>



## Execution


| Kind | Description |
|------|-------------|
| `exec.native` | Native command execution |
| `exec.docker` | Docker container execution |

```yaml
- name: native_exec
  kind: exec.native
  default_work_dir: "/app"
  command_whitelist:
    - "ls"
    - "cat"

- name: docker_exec
  kind: exec.docker
  image: "python:3.11-slim"
  default_work_dir: "/workspace"
  auto_remove: true
  memory_limit: 536870912  # 512MB
  command_whitelist:
    - "python"
```



## WASM Runtime


| Kind | Description |
|------|-------------|
| `function.wat` | WebAssembly function (WAT text format) |
| `function.wasm` | WebAssembly function (binary) |
| `process.wasm` | WebAssembly process |

```yaml


# WAT text is inline source

- name: sum_wat
  kind: function.wat
  source: file://sum.wat
  method: sum
  transport: payload   # or wasi-http



# Binary WASM is loaded from a filesystem entry and verified by hash

- name: sum
  kind: function.wasm
  fs: app:modules
  path: sum.wasm
  hash: sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae
  method: sum
  transport: payload
```

`function.wasm` and `process.wasm` take `fs`, `path`, and `hash` — there is no `source` field on a binary entry; `source` belongs to `function.wat` only. `hash` is required and must be `sha256:<hex>`; the module is rejected if the bytes do not match.

See [WASM Overview](wasm/overview.md).



## Networks


| Kind | Description |
|------|-------------|
| `network` | Base network overlay |
| `network.socks5` | SOCKS5 proxy overlay |
| `network.i2p` | I2P network overlay |
| `network.tailscale` | Tailscale overlay |

Referenced by `http.service` via `network:`, by `funcs`/`process` via the `network` option, and by `http_client` via the `overlay_network` option. See [Network](system/network.md).



## Registry Primitives


| Kind | Description |
|------|-------------|
| `registry.entry` | Plain data entry with no service behind it (app-specific config) |
| `ns.definition` | Namespace definition |
| `ns.requirement` | Namespace requirement declaration |
| `ns.dependency` | Namespace dependency |

The `ns.*` kinds are authored like any other entry: a component declares `ns.definition` and `ns.requirement`, and a host declares `ns.dependency`. See [Building Components](guides/components.md).



## Lifecycle Configuration


Supervisor-managed service entries expose lifecycle configuration. The block below belongs inside a service entry that supports it:

```yaml
lifecycle:
  auto_start: true          # Start automatically
  start_timeout: 10s        # Max startup time
  stop_timeout: 10s         # Max shutdown time
  stable_threshold: 5s      # Uninterrupted run time before retry accounting resets
  requires:
    - app:database
  restart:                  # Retry policy
    initial_delay: 1s
    max_delay: 90s
    backoff_factor: 2.0
    max_attempts: 0         # 0 = infinite
```

<note>
Use <code>depends_on</code> to ensure entries start in the correct order. The supervisor starts a dependent entry only after each of its dependencies has completed its own start.
</note>



## Entry Reference Format


Entries are referenced using `namespace:name` format:

```yaml


# Definition

namespace: app.users
entries:
  - name: handler
    kind: function.lua



# Reference from another entry

func: app.users:handler
```



## Overriding Entries


Any entry's fields — including its `kind` — can be overridden at launch without editing the source YAML, using the `override:` config section or the `-o` CLI flag. Keys use `namespace:entry:path` format:

```yaml
override:
  app:gateway:addr: ":9090"        # data field (a bare path targets data.*)
  app:worker:meta.priority: high    # meta field
  app:db:kind: db.sql.postgres      # the entry's typed kind
  app:db:data.kind: custom          # a payload field literally named "kind"
```

| Path | Targets |
|------|---------|
| `kind` | The entry's typed kind (must be a non-empty string) |
| `data.<field>` or bare `<field>` | A field in the entry's data payload |
| `meta.<field>` | A field in the entry's metadata |

The same overrides apply from the CLI:

```bash
wippy run -o app:db:kind=db.sql.postgres -o app:gateway:addr=:9090
```

CLI (`-o`) values coerce by shape (`true`/`false` to bool, numbers to numbers, otherwise string); `override:` section values keep their YAML type. To override global [configuration](guides/configuration.md) sections instead of entries, use `--set`.



## Navigation

Previous: "Building Components" (guides/components)
Next: "Observability" (guides/observability)
