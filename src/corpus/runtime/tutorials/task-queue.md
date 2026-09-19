# "Task Queue"

_Path: en/tutorials/task-queue_

> "Build a REST API that queues tasks for background processing with database persistence."

## Table of Contents

- Task Queue

## Content

# Task Queue


Build a REST API that publishes tasks to an in-memory queue, processes them in background workers, and stores completed results in SQLite.

**Classification:** Runnable tutorial. The page provides the complete registry, Lua
sources, startup commands, and HTTP checks for a local single-node demo.



## Overview


This tutorial creates a task management API demonstrating:

- **REST endpoints** — Submit tasks and list results
- **Queue publishing** — Dispatch jobs asynchronously
- **Queue consumers** — Process jobs in background workers
- **Database persistence** — Store completed results in SQLite
- **Schema setup** — Create the database table in a one-shot process

```mermaid
flowchart LR
    subgraph api["HTTP Server"]
        POST["/tasks POST"]
        GET["/tasks GET"]
    end

    subgraph queue["Queue"]
        Q[("tasks queue")]
    end

    subgraph workers["Workers"]
        W1["Consumer 1"]
        W2["Consumer 2"]
    end

    subgraph storage["Storage"]
        DB[(SQLite)]
    end

    POST -->|publish| Q
    Q --> W1
    Q --> W2
    W1 -->|INSERT| DB
    W2 -->|INSERT| DB
    GET -->|SELECT| DB
```



## Prerequisites


- Wippy runtime `v0.3.32a`.
- `curl` or another HTTP client.
- An empty working directory. Create the project and source directory before adding
  the files below:

  ```bash
  mkdir task-queue
  cd task-queue
  mkdir src
  ```



## Project Structure


```
task-queue/
├── wippy.lock
├── data/                    # created before startup
└── src/
    ├── _index.yaml
    ├── migrate.lua
    ├── create_task.lua
    ├── list_tasks.lua
    └── process_task.lua
```



## Entry Definitions


Create `src/_index.yaml`:

```yaml
version: "1.0"
namespace: app

entries:
  # Capabilities used by the tutorial's Lua entries in strict mode
  - name: runtime_policy
    kind: security.policy
    policy:
      actions:
        - db.get
        - queue.publish
        - queue.publish.queue
      resources: "*"
      effect: allow

  # SQLite database
  - name: db
    kind: db.sql.sqlite
    file: "./data/tasks.db"
    lifecycle:
      auto_start: true

  # Access policy for handlers, workers, and the migration
  - name: task_policy
    kind: security.policy
    policy:
      actions:
        - db.get
        - queue.publish
        - queue.publish.queue
      resources: "*"
      effect: allow

  # Memory queue driver
  - name: queue_driver
    kind: queue.driver.memory
    lifecycle:
      auto_start: true

  # Tasks queue
  - name: tasks_queue
    kind: queue.queue
    driver: app:queue_driver

  # HTTP server
  - name: gateway
    kind: http.service
    addr: ":8080"
    lifecycle:
      auto_start: true

  # Router
  - name: router
    kind: http.router
    meta:
      server: app:gateway

  # Migration process (runs once, exits)
  - name: migrate
    kind: process.lua
    source: file://migrate.lua
    method: main
    modules:
      - sql
      - logger
    security:
      actor:
        id: "service:migrate"
      policies:
        - app:task_policy

  # Migration service (auto-starts, exits on success)
  - name: migrate-service
    kind: process.service
    process: app:migrate
    host: app:processes
    lifecycle:
      auto_start: true

  # Process host
  - name: processes
    kind: process.host
    lifecycle:
      auto_start: true

  # API handlers
  - name: create_task
    kind: function.lua
    source: file://create_task.lua
    method: handler
    modules:
      - http
      - queue
      - uuid
    security:
      actor:
        id: "service:api"
      policies:
        - app:task_policy

  - name: list_tasks
    kind: function.lua
    source: file://list_tasks.lua
    method: handler
    modules:
      - http
      - sql
    security:
      actor:
        id: "service:api"
      policies:
        - app:task_policy

  # Queue worker
  - name: process_task
    kind: function.lua
    source: file://process_task.lua
    method: main
    modules:
      - sql
      - logger
      - json
    security:
      actor:
        id: "service:worker"
      policies:
        - app:task_policy

  # Endpoints
  - name: create_task.endpoint
    kind: http.endpoint
    meta:
      router: app:router
    method: POST
    path: /tasks
    func: app:create_task

  - name: list_tasks.endpoint
    kind: http.endpoint
    meta:
      router: app:router
    method: GET
    path: /tasks
    func: app:list_tasks

  # Queue consumer
  - name: task_consumer
    kind: queue.consumer
    queue: app:tasks_queue
    func: app:process_task
    concurrency: 2
    prefetch: 5
    lifecycle:
      auto_start: true
```

<tip>
Strict mode is on by default, so an entry that reaches the database or the queue needs an actor and a scope. The `security:` block on each Lua entry supplies both from `app:task_policy`. See [Security Model](system/security.md).
</tip>



## Migration Process


Create `src/migrate.lua`:

```lua
local sql = require("sql")
local logger = require("logger")

local function main()
    local db, err = sql.get("app:db")
    if err then
        logger:error("failed to connect", {error = tostring(err)})
        error("failed to connect: " .. tostring(err))
    end

    local _, exec_err = db:execute([[
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            result TEXT,
            created_at INTEGER NOT NULL,
            processed_at INTEGER
        )
    ]])

    db:release()

    if exec_err then
        logger:error("migration failed", {error = tostring(exec_err)})
        error("migration failed: " .. tostring(exec_err))
    end

    logger:info("migration complete")
    return 0
end

return { main = main }
```

<tip>
A normal return ends a `process.service` child without a restart; the supervisor
retries only when the process raises an error. Returning `0` also maps to a successful
exit status when the same process is launched as a CLI command.
</tip>



## Create Task Endpoint


Create `src/create_task.lua`:

```lua
local http = require("http")
local queue = require("queue")
local uuid = require("uuid")

local function handler()
    local req = http.request()
    local res = http.response()

    local body, parse_err = req:body_json()
    if parse_err then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({error = "invalid JSON"})
        return
    end

    if not body.action then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({error = "action required"})
        return
    end

    local task_id = uuid.v4()
    local task = {
        id = task_id,
        action = body.action,
        data = body.data or {},
        created_at = os.time()
    }

    local ok, err = queue.publish("app:tasks_queue", task)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({error = "failed to queue task"})
        return
    end

    res:set_status(http.STATUS.ACCEPTED)
    res:write_json({
        id = task_id,
        status = "queued"
    })
end

return { handler = handler }
```



## List Tasks Endpoint


Create `src/list_tasks.lua`:

```lua
local http = require("http")
local sql = require("sql")

local function handler()
    local req = http.request()
    local res = http.response()

    local db, db_err = sql.get("app:db")
    if db_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({error = "database unavailable"})
        return
    end

    local status_filter = req:query("status")

    local query = sql.builder.select("id", "payload", "status", "result", "created_at", "processed_at")
        :from("tasks")
        :order_by("created_at DESC")
        :limit(100)

    if status_filter then
        query = query:where({status = status_filter})
    end

    local rows, query_err = query:run_with(db):query()
    db:release()

    if query_err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({error = "query failed"})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        tasks = rows,
        count = #rows
    })
end

return { handler = handler }
```



## Queue Worker


Create `src/process_task.lua`:

```lua
local sql = require("sql")
local logger = require("logger")
local json = require("json")

local function main(task)
    logger:info("processing task", {
        id = task.id,
        action = task.action
    })

    local result
    if task.action == "uppercase" then
        result = {output = string.upper(task.data.text or "")}
    elseif task.action == "sum" then
        local nums = task.data.numbers or {}
        local total = 0
        for _, n in ipairs(nums) do
            total = total + n
        end
        result = {output = total}
    else
        result = {output = "processed"}
    end

    local db, db_err = sql.get("app:db")
    if db_err then
        error("database unavailable: " .. tostring(db_err))
    end

    local _, exec_err = db:execute(
        "INSERT OR REPLACE INTO tasks (id, payload, status, result, created_at, processed_at) VALUES (?, ?, ?, ?, ?, ?)",
        { task.id, json.encode(task), "completed", json.encode(result), task.created_at, os.time() }
    )
    db:release()

    if exec_err then
        error("failed to store result: " .. tostring(exec_err))
    end

    logger:info("task completed", {id = task.id})
end

return { main = main }
```

<note>
The consumer auto-acks when the handler returns normally and auto-nacks when it raises an error. Call `msg:ack()` or `msg:nack()` via `queue.message()` only when you need explicit control before the handler ends.
</note>



## Running the Service


Create the data directory, initialize the project, and start the runtime:

```bash
mkdir data
wippy init
wippy run
```

Leave the runtime running while you use a second terminal for the HTTP checks. Wait
until the logs report that the HTTP service is listening and the migration completed;
the one-shot migration and the HTTP service start independently during boot.

Submit a task and query its result:

```bash


# Create a task

curl -X POST http://localhost:8080/tasks \
  -H "Content-Type: application/json" \
  -d '{"action": "uppercase", "data": {"text": "hello world"}}'



# Wait a moment for processing, then list tasks

curl http://localhost:8080/tasks



# Filter by status

curl "http://localhost:8080/tasks?status=completed"
```

The returned row should have `status: "completed"`; its `result` field is a JSON
string containing `{"output":"HELLO WORLD"}`. The in-memory queue is intentionally
non-durable, but completed rows survive restarts in `data/tasks.db`.



## Troubleshooting and Cleanup


- `no such table: tasks` means the request reached SQLite before the migration
  finished. Wait for `migration complete` and retry. A migration error stops the
  migration service and is shown in the runtime logs.
- `failed to queue task` usually means `app:queue_driver` or
  `app:task_consumer` did not start. Check the startup logs for the first resource
  error rather than retrying the request.
- `address already in use` means another process owns port 8080. Stop it or change
  `app:gateway.addr` and use the same port in the `curl` commands.
- Stop the runtime with Ctrl+C. Remove `data/tasks.db` to reset the tutorial data;
  the next start recreates the schema.



## Message Flow


1. **POST /tasks** receives the request, generates a UUID, and publishes the task.
2. A **queue consumer** receives the message; up to two handlers run concurrently.
3. The **worker** processes the task and writes its result to SQLite.
4. **GET /tasks** reads completed tasks from the database.



## Next Steps


- [HTTP Module](lua/http/http.md) — Request and response handling
- [Queue Module](lua/storage/queue.md) — Message queue operations
- [SQL Module](lua/storage/sql.md) — Database access
- [Queue Consumers](guides/queue-consumers.md) — Queue configuration



## Navigation

Previous: "Process Supervision Recipes" (tutorials/supervision)
Next: "Testing" (tutorials/testing)
