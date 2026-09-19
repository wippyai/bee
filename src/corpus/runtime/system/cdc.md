# "Change Data Capture"

_Path: en/system/cdc_

> "Stream row-level changes from Postgres logical replication or SQLite with db.cdc.postgres and db.cdc.sqlite."

## Table of Contents

- Change Data Capture

## Content

# Change Data Capture


Stream row-level changes from a database. A CDC source captures inserts, updates and deletes, optionally hands each subscriber a consistent snapshot of existing rows first, and delivers everything as driver-neutral change events. Sources are addressable by their entry ID and consumed from Lua via the [`cdc` module](lua/storage/cdc.md).



## Entry Kinds


| Kind | Description |
|------|-------------|
| `db.cdc.postgres` | Postgres logical replication (`pgoutput` plugin) |
| `db.cdc.sqlite` | SQLite writes observed through a `db.sql.sqlite` resource |

Both kinds expose the same Lua API, the same source info record and the same change event shape. What differs is the guarantee set, published per source as [capabilities](#capabilities).



## Postgres Configuration


```yaml
- name: pg_cdc
  kind: db.cdc.postgres
  host: ${env:DB_HOST}
  port: 5432
  database: app
  username: ${env:DB_USER}
  password: ${env:app.secrets:db_password}
  slot_name: wippy_slot
  publication: wippy_pub
  tables:
    - public.users
    - public.orders
  snapshot: true
  streaming: true
  standby_interval: "10s"
  status_interval: "10s"
  lifecycle:
    auto_start: true
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `host` | string | required | Postgres host |
| `port` | int | required | Postgres port (must be > 0) |
| `database` | string | required | Database name |
| `username` | string | required | Replication user (must have `REPLICATION` privilege) |
| `password` | string | required | Password (inline or `${env:NAME}`) |
| `slot_name` | string | required | Logical replication slot name |
| `publication` | string | - | Postgres publication; required when `tables` is empty |
| `tables` | []string | - | Tables to capture (`schema.table`); omit to use the publication's tables |
| `snapshot` | bool | false | Entry default for the per-subscriber snapshot handoff |
| `streaming` | bool | false | Use the streaming `pgoutput` protocol version |
| `temporary` | bool | false | Use a temporary replication slot (removed on disconnect) |
| `failover` | bool | false | Enable failover slot mode (mutually exclusive with `temporary`) |
| `standby_interval` | duration | `10s` | Standby status message interval (e.g. `10s`) |
| `status_interval` | duration | `30s` | Status update interval to the server |
| `snapshot_fetch_size` | int | 1000 | Rows fetched per snapshot batch (must be >= 0) |
| `max_transaction_changes` | int | 1000000 | Maximum changes buffered while decoding one transaction |
| `max_transaction_bytes` | int | 268435456 | Maximum logical bytes buffered while decoding one transaction (256 MiB) |
| `max_inflight_changes` | int | 1000000 | Maximum changes held across all in-flight transactions |
| `max_inflight_bytes` | int | 268435456 | Maximum logical bytes held across all in-flight transactions (256 MiB) |
| `subscriptions` | object | - | Subscription admission limits, see [Subscription Limits](#subscription-limits) |
| `options` | map | - | Extra connection options |
| `lifecycle` | object | - | Lifecycle configuration |

Zero on any `max_*` field selects the default; the decoder is never unbounded. Negative values are rejected.

Credentials resolve `${env:NAME}` placeholders through the [environment registry](system/env.md) at decode time.



## SQLite Configuration


A SQLite source does not open its own database. It borrows an existing [`db.sql.sqlite`](system/database.md) resource and subscribes to that resource's committed-mutation observer, so it captures exactly the writes made through that Wippy SQL resource — writes by another process, another connection or an external tool are not observed.

```yaml
- name: cdcdb
  kind: db.sql.sqlite
  file: /var/data/app.db
  lifecycle:
    auto_start: true

- name: changes
  kind: db.cdc.sqlite
  db_resource: app:cdcdb
  tables:
    - users
    - orders
  snapshot: true
  status_interval: "30s"
  lifecycle:
    auto_start: true
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `db_resource` | string | required | Entry ID of the `db.sql.sqlite` resource to observe |
| `name` | string | - | Accepted; the source name is always the entry ID |
| `tables` | []string | - | Tables to capture; omit for all tables |
| `snapshot` | bool | false | Entry default for the per-subscriber snapshot handoff |
| `status_interval` | duration | `30s` | Status update interval |
| `subscriptions` | object | - | Subscription admission limits, see [Subscription Limits](#subscription-limits) |
| `lifecycle` | object | - | Lifecycle configuration |

The source declares the SQL resource as a lifecycle requirement, so the supervisor starts the database first and restarts the source when the database generation is replaced.

<note>
SQLite capture requires a runtime built with the <code>sqlite_preupdate_hook</code> build tag. Official builds include it. Without the tag the driver fails closed: creating a <code>db.cdc.sqlite</code> entry returns <code>sqlite cdc requires the sqlite_preupdate_hook build tag</code> rather than starting a source that captures nothing.
</note>



## Subscription Limits


Each source admits a bounded number of subscribers and reserves their worst-case backlog up front. A snapshot slot stays reserved until the snapshot-enabled stream closes.

```yaml
subscriptions:
  max_subscriptions: 1024
  max_snapshot_subscriptions: 4
  max_bytes: 268435456
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_subscriptions` | int | 1024 | Concurrent subscriptions admitted by the source |
| `max_snapshot_subscriptions` | int | 4 | Concurrent snapshot-enabled subscriptions |
| `max_bytes` | int | 268435456 | Total reserved subscriber backlog bytes (256 MiB) |

Zero selects the default; negative values are rejected. Exhausting a limit fails the subscription with a retryable `errors.UNAVAILABLE`.



## How It Works


1. A Postgres source connects as a replication user and creates (or resumes) the slot named by `slot_name`. A SQLite source borrows its `db_resource` and subscribes to that resource's committed-mutation observer.
2. Row changes are decoded into driver-neutral change events with `op` of `insert`, `update`, `delete` or `truncate`.
3. A subscriber whose stream has `snapshot` enabled — from the entry's `snapshot` field or from `opts.snapshot` on the stream — first receives the existing rows as events with `op = "snapshot"`, then continues into live changes with no gap between the two.
4. A Postgres source periodically acknowledges the LSN so the server can release WAL segments (`standby_interval`).
5. The source registers under its entry ID; Lua code subscribes with [`cdc.stream`](lua/storage/cdc.md).



## Capabilities


Every source publishes what it guarantees, so consumers branch on capabilities rather than on the entry kind.

| Capability | `db.cdc.postgres` | `db.cdc.sqlite` | Meaning |
|------------|:-----------------:|:---------------:|---------|
| `snapshot` | yes | yes | Supports the atomic snapshot/live handoff |
| `capture_resume` | yes, unless `temporary` | no | Source progress survives a reconnect |
| `replayable` | no | no | Individual subscribers can replay past events |
| `captures_external_writes` | yes | no | Captures writes made outside this runtime |
| `before_images` | no | yes | Guarantees a full pre-change row image on `update` and `delete` |
| `coalesced` | no | yes | Repeated writes to a row within a transaction may arrive coalesced |

Capability flags describe source progress, not durable delivery: no driver replays events for an individual subscriber that fell behind or disconnected.



## Source Info


Each source is described by an info record, returned by `cdc.source` and `cdc.list_sources`.

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Entry ID |
| `kind` | string | `db.cdc.postgres` or `db.cdc.sqlite` |
| `name` | string | Source name (the entry ID) |
| `state` | string | `unknown`, `starting`, `running`, `faulted` or `stopped` |
| `generation` | string | Current source generation; changes when the source is replaced |
| `epoch` | string | Same value as `generation` |
| `engine` | string | Engine name (`sqlite`) |
| `db_resource` | string | Observed SQL resource entry ID (`db.cdc.sqlite`) |
| `slot` | string | Replication slot name (`db.cdc.postgres`) |
| `publication` | string | Postgres publication, when configured |
| `tables` | []string | Captured tables, when configured |
| `streaming` | bool | Whether the source is currently running |
| `failover` | bool | Failover slot mode (`db.cdc.postgres`) |
| `temporary` | bool | Temporary slot (`db.cdc.postgres`) |
| `snapshot` | bool | Entry-level snapshot default |
| `faulted` | bool | Whether the source is in the `faulted` state |
| `error` | string | Last source error, when one is recorded |
| `admission` | object | `active`, `snapshots`, `reserved_bytes`, `rejected` |
| `capabilities` | object | See [Capabilities](#capabilities) |

`admission` counts reservations, not queue fill: `active` is the admitted subscription count, `snapshots` the snapshot-enabled subset, `reserved_bytes` the reserved backlog budget, and `rejected` the cumulative number of subscriptions refused by the limits.



## Permissions


| Action | Resource | Description |
|--------|----------|-------------|
| `cdc.source` | Source entry ID | Read source info; also filters `cdc.list_sources` |
| `cdc.subscribe` | Source entry ID | Open a change stream |

CDC authority is separate from database access: a source can expose every captured row, including before images. Stream filters narrow delivery only; they never grant access to a source.

```yaml
- name: cdc_reader
  kind: security.policy
  policy:
    effect: allow
    actions: [cdc.source, cdc.subscribe]
    resources: [app:changes]
```



## See Also


- [CDC Module](lua/storage/cdc.md) - Lua streaming API
- [Database](system/database.md) - SQL database services
- [Environment](system/env.md) - Resolving credentials via `${env:NAME}`
- [Security](system/security.md) - Policies and actions



## Navigation

Previous: "Database System" (system/database)
Next: "Store (Key-Value)" (system/store)
