# "CDC"

_Path: en/lua/storage/cdc_

> "Subscribe to Change Data Capture streams from db.cdc.postgres and db.cdc.sqlite sources. List configured sources, open a stream, and receive…"

## Table of Contents

- CDC

## Content

# CDC

<secondary-label ref="storage"/>
<secondary-label ref="stream"/>
<secondary-label ref="nondeterministic"/>

Subscribe to Change Data Capture streams from [`db.cdc.postgres`](system/cdc.md) and [`db.cdc.sqlite`](system/cdc.md) sources. List configured sources, open a stream, and receive row-level change events over a channel. The API is driver-neutral: both kinds return the same source info and the same change events, and differ only in the [capabilities](system/cdc.md#capabilities) they publish.



## Loading


```lua
local cdc = require("cdc")
```



## `list_sources`


List the configured CDC sources the caller is allowed to see:

```lua
local sources, err = cdc.list_sources()
if err then return nil, err end
for _, s in ipairs(sources) do
    print(s.id, s.kind, s.state, s.capabilities.before_images)
end
```

Sources the caller lacks `cdc.source` on are omitted rather than reported as an error.

**Returns:** `table, error`



## `source`


Retrieve one source by its registry entry ID or replication slot name:

```lua
local info, err = cdc.source("app:pg_cdc")
if err then return nil, err end
if info == nil then
    -- no such source
end
```

**Returns:** `table, error` (source info, or `nil` if not found)



## `stream`


Open a change stream on a source. The returned `cdc.Stream` exposes a channel that delivers change events:

```lua
local stream, err = cdc.stream("app:pg_cdc", {
    tables = { "public.users", "public.orders" },
    ops    = { "insert", "update" },
    buffer = 128,
})
if err then return nil, err end

-- The caller owns stream until close(), release(), or task cleanup.
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | Source name (entry ID) |
| `opts.tables` | []string | - | Filter to these tables (omit for all captured tables) |
| `opts.ops` | []string | - | Filter to these operations: `insert`, `update`, `delete`, `truncate` |
| `opts.buffer` | int | 64 | Backlog item capacity (1-65536) |
| `opts.max_bytes` | int | 1048576 | Backlog byte budget for this subscriber (1 MiB) |
| `opts.snapshot` | bool | entry default | Request the snapshot/live handoff for this stream |
| `opts.after` | string | - | Opaque resume cursor from a previous event's `cursor` |

Unknown option keys are rejected with `errors.INVALID`. Table names are matched case-insensitively against both the qualified relation and the bare table name. Snapshot rows are filtered by `tables` only; `ops` applies to live changes.

A stream receives a snapshot when either `opts.snapshot` is true or the source entry's `snapshot` field is set; snapshot rows arrive first with `op = "snapshot"`, then the stream continues into live changes with no gap. `opts.after` is reserved for drivers that resume from a cursor — every driver shipped today returns `errors.INVALID` ("cdc operation is not supported by this source") for it, including `db.cdc.postgres` when it reports `capture_resume`.

Filters narrow delivery only. Access to a source is granted by the `cdc.subscribe` permission, never by a filter.

**Returns:** `Stream, error`

The Lua delivery channel has a separate fixed capacity of 64. The `buffer` option controls the PostgreSQL source subscription, not that channel.



### `channel`


Return the channel that receives change events. The first call subscribes to the source and yields; subsequent calls return the same channel. The first call can return a subscription error. Channel `:receive()` returns `value, true` for a change or `nil, false` when the stream ends:

```lua
local stream, stream_err = cdc.stream("app:pg_cdc")
if stream_err then return nil, stream_err end
local ch, subscribe_err = stream:channel()
if subscribe_err then
    stream:close()
    return nil, subscribe_err
end

while true do
    local change, ok = ch:receive()
    if not ok then break end

    if change.op == "snapshot" then
        seed_row(change.table, change.after)
    elseif change.op == "insert" then
        handle_new_user(change.table, change.after)
    elseif change.op == "update" then
        handle_update(change.table, change.before, change.after)
    elseif change.op == "delete" then
        handle_delete(change.table, change.before)
    end
end

local _, close_err = stream:close()
if close_err then return nil, close_err end
```

The stream is lazy: construct it, then call `channel()` before generating the writes it should observe. This is live observation, not replay of changes made before the subscription.

When a source terminates a stream with a failure, the channel delivers an error value before it closes. `receive` is an alias for `channel`.



### `close`


Stop the subscription and release the stream. The method is idempotent, and the runtime also closes the stream at the end of the task scope. `release` is an alias for `close`.

```lua
local _, err = stream:close()
if err then return nil, err end
```



## Change Event


Each message received on the channel is a change table:

| Field | Description |
|-------|-------------|
| `op` | Operation: `insert`, `update`, `delete`, `snapshot` or `truncate` |
| `schema` | Table schema |
| `table` | Table name |
| `relation` | Qualified relation name |
| `before` | Row state before the change (`update`, `delete`). A full row image is guaranteed only when the source has the `before_images` capability; `db.cdc.postgres` fills it from whatever old tuple the WAL carries, which the table's `REPLICA IDENTITY` controls |
| `after` | Row state after the change (`insert`, `update`, `snapshot`; absent for `delete`) |
| `source` | Source entry ID |
| `source_id` | Source entry ID, as a registry ID |
| `generation` | Source generation that produced the event |
| `cursor` | Opaque per-event position within the source |
| `transaction` | Transaction identifier, when the driver reports one |
| `lsn` | Log sequence number of the change (`db.cdc.postgres`) |
| `commit_lsn` | LSN of the committing transaction (when applicable) |
| `xid` | Transaction ID (when applicable) |
| `unchanged` | Columns whose value was not transmitted (unchanged TOAST values) |
| `error` | Driver-reported error description carried on the event |

`before` and `after` are row maps keyed by column name.



## Source Info


`cdc.source` and each entry of `cdc.list_sources` return the same record:

| Field | Description |
|-------|-------------|
| `id` | Entry ID |
| `kind` | `db.cdc.postgres` or `db.cdc.sqlite` |
| `name` | Source name (the entry ID) |
| `state` | `unknown`, `starting`, `running`, `faulted` or `stopped` |
| `generation` | Current source generation |
| `epoch` | Same value as `generation` |
| `engine` | Engine name, when the driver reports one |
| `db_resource` | Observed SQL resource entry ID (`db.cdc.sqlite`) |
| `slot` | Replication slot name (`db.cdc.postgres`) |
| `publication` | Postgres publication, when configured |
| `tables` | Captured tables, when configured |
| `streaming` | `db.cdc.sqlite`: whether the source is running; `db.cdc.postgres`: the entry's `streaming` protocol setting |
| `failover` | Failover slot mode (`db.cdc.postgres`) |
| `temporary` | Temporary slot (`db.cdc.postgres`) |
| `snapshot` | Entry-level snapshot default |
| `faulted` | Whether the source is in the `faulted` state |
| `error` | Last source error, when one is recorded |
| `admission` | `active`, `snapshots`, `reserved_bytes`, `rejected` |
| `capabilities` | `snapshot`, `capture_resume`, `replayable`, `captures_external_writes`, `before_images`, `coalesced` |

Branch on `capabilities` rather than on `kind`:

```lua
local info = cdc.source("app:changes")
if not info.capabilities.before_images then
    -- before is not a guaranteed full row image; keep your own last-known state
end
```

See [CDC sources](system/cdc.md#source-info) for field semantics.



## Permissions


| Action | Resource | Description |
|--------|----------|-------------|
| `cdc.source` | Source entry ID | `cdc.source`; also filters `cdc.list_sources` |
| `cdc.subscribe` | Source entry ID | `cdc.stream`, checked again when the subscription is established |

A denied action returns `errors.PERMISSION_DENIED`.



## Errors


| Condition | Kind |
|-----------|------|
| No context | `errors.INTERNAL` |
| Source name required | `errors.INVALID` |
| Invalid or unknown stream option | `errors.INVALID` |
| `after` on a source without `capture_resume` | `errors.INVALID` |
| Source not registered | `errors.NOT_FOUND` |
| Source not started or replacing | `errors.UNAVAILABLE` |
| Subscription capacity exhausted | `errors.UNAVAILABLE` |
| Permission denied | `errors.PERMISSION_DENIED` |

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Change Data Capture](system/cdc.md) - Source configuration and capabilities
- [Channel](lua/core/channel.md) - Channel semantics
- [Database](system/database.md) - SQL database services



## Navigation

Previous: "Message Queue" (lua/storage/queue)
Next: "System" (lua/system/system)
