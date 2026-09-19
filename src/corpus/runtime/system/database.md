# "Database System"

_Path: en/system/database_

> "SQL database connection pooling and configuration. Supports PostgreSQL, MySQL, and SQLite."

## Table of Contents

- Database System

## Content

# Database System


Wippy provides pooled SQL database entries for PostgreSQL and MySQL, plus a single-connection SQLite entry.

This page is a configuration reference. Unless a fence includes `version`, `namespace`, and `entries`, treat it as a fragment to place inside an existing entry list.



## Entry Kinds


| Kind | Description |
|------|-------------|
| `db.sql.postgres` | PostgreSQL database |
| `db.sql.mysql` | MySQL database |
| `db.sql.sqlite` | SQLite database |



### Standard Databases (PostgreSQL, MySQL)


```yaml


# src/data/_index.yaml

version: "1.0"
namespace: app.data

entries:
  - name: main_db
    kind: db.sql.postgres
    host: "localhost"
    port: 5432
    database: "myapp"
    username: "dbuser"
    password: ${env:app.secrets:db_password}
    pool:
      max_open: 25
      max_idle: 5
      max_lifetime: "1h"
    options:
      sslmode: "disable"
    lifecycle:
      auto_start: true
```



### SQLite


```yaml
  - name: cache_db
    kind: db.sql.sqlite
    file: "/var/data/cache.db"  # Use :memory: for in-memory
    pool:
      max_open: 4
      max_idle: 2
      max_lifetime: "1h"
    lifecycle:
      auto_start: true
```

<note>
A private in-memory SQLite database (<code>file: ":memory:"</code>) is scoped to one physical connection, so <code>max_open</code> and <code>max_idle</code> are forced to <code>1</code>. A file-backed database honors the configured <code>pool</code> settings, which a CDC snapshot read transaction needs so it does not consume the only writer connection. Journal mode is always <code>WAL</code>.
</note>



### Standard Database Fields


| Field | Type | Description |
|-------|------|-------------|
| `host` | string | Database host address |
| `port` | int | Database port number |
| `database` | string | Database name |
| `username` | string | Database user |
| `password` | string | Database password |
| `pool` | object | Connection pool settings |
| `options` | map | Database-specific options |
| `lifecycle` | object | Lifecycle configuration |



### SQLite Fields


| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `file` | string | required | Database file path or `:memory:` |
| `pool` | object | - | Connection pool settings; `max_open` and `max_idle` are forced to `1` for `:memory:` |
| `max_mutation_changes` | int | 100000 | Rows one transaction may hold in the committed-mutation observer |
| `max_mutation_bytes` | int | 67108864 | Logical bytes one transaction may hold in the observer (64 MiB) |
| `options` | map | - | Accepted but ignored |
| `lifecycle` | object | - | Lifecycle configuration |

`max_mutation_changes` and `max_mutation_bytes` bound the in-memory committed-mutation observer that feeds a [`db.cdc.sqlite`](system/cdc.md) source. Zero on either field selects the default; negative values are rejected. The bounds are conservative rather than exact: SQLite delivers a complete row to the pre-update hook, so one row can materialize before the bound rejects the candidate.



### Secret and Environment Values


Pull connection values from the [environment registry](system/env.md) with `${env:NAME}` placeholders, resolved at decode time. `NAME` is a registered variable's public name or its entry ID (e.g. `app.secrets:db_password`); it is not a raw OS env var.

```yaml
- name: prod_db
  kind: db.sql.postgres
  host: ${env:DB_HOST}
  port: ${env:DB_PORT|5432}
  database: ${env:DB_NAME}
  username: ${env:DB_USER}
  password: ${env:app.secrets:db_password}
```

<note>
Older configurations use a sibling <code>&lt;field&gt;_env</code> directive (<code>host_env</code>, <code>port_env</code>, <code>database_env</code>, <code>username_env</code>, <code>password_env</code>) that resolves the same way. This form is <b>deprecated</b> — migrate it to the <code>${env:NAME}</code> placeholder shown above.
</note>

<warning>
Avoid hardcoding passwords in configuration. Use <code>env.variable</code> entries for credentials. See <a href="./env.md">Environment</a> for secret configuration.
</warning>



## Connection Pool


Configure connection pooling behavior. Pool settings map to Go's [database/sql connection pool](https://pkg.go.dev/database/sql#DB.SetMaxOpenConns).

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_open` | int | 0 | Maximum open connections (0 = unlimited) |
| `max_idle` | int | 0 | Maximum idle connections (0 = no idle connections retained) |
| `max_lifetime` | duration | 1h | Maximum connection lifetime |

```yaml
pool:
  max_open: 25      # Limit concurrent connections
  max_idle: 5       # Keep 5 connections ready
  max_lifetime: "30m"  # Recycle connections every 30 minutes
```

<tip>
Set <code>max_idle</code> less than or equal to <code>max_open</code>. Connections exceeding <code>max_lifetime</code> are closed and replaced, helping recover from stale connections.
</tip>



## DSN Formats


Each database type constructs a DSN from configuration. Any `options` are appended (sorted by key); none are included by default.



### PostgreSQL {id="dsn-postgresql"}


```
host='host' port=port user='username' password='password' dbname='database' [option='value' ...]
```

Every value except the port is single-quoted, and embedded `'` and `\` are backslash-escaped, so hosts, passwords and option values containing spaces or quotes are passed through intact.



### MySQL {id="dsn-mysql"}


```
username:password@tcp(host:port)/database[?option=value&...]
```



### SQLite {id="dsn-sqlite"}


```
file:/path/to/database.db?mode=rwc
:memory:
```



## Database Options


Common database-specific options:



### PostgreSQL {id="options-postgresql"}


```yaml
options:
  sslmode: "require"      # disable, require, verify-ca, verify-full
  connect_timeout: "10"   # Connection timeout in seconds
  application_name: "myapp"
```



### MySQL {id="options-mysql"}


```yaml
options:
  charset: "utf8mb4"
  parseTime: "true"       # Parse time values to time.Time
  loc: "Local"            # Timezone
```



### SQLite {id="options-sqlite"}


SQLite does not apply the `options` map to its DSN. File databases always open with `mode=rwc`, and journal mode is always set to `WAL`. The `options` field is accepted but ignored.



### PostgreSQL with SSL


```yaml
- name: secure_postgres
  kind: db.sql.postgres
  host: "db.example.com"
  port: 5432
  database: "production"
  username: "app_user"
  password: ${env:app.secrets:db_password}
  pool:
    max_open: 50
    max_idle: 10
    max_lifetime: "1h"
  options:
    sslmode: "verify-full"
    sslcert: "/certs/client.crt"
    sslkey: "/certs/client.key"
    sslrootcert: "/certs/ca.crt"
  lifecycle:
    auto_start: true
```



### MySQL Read Replica


```yaml
- name: mysql_replica
  kind: db.sql.mysql
  host: "replica.db.example.com"
  port: 3306
  database: "app"
  username: "readonly"
  password: ${env:app.secrets:replica_password}
  pool:
    max_open: 20
    max_idle: 5
    max_lifetime: "30m"
  options:
    charset: "utf8mb4"
    parseTime: "true"
    readTimeout: "30s"
```



### SQLite In-Memory


```yaml
- name: test_db
  kind: db.sql.sqlite
  file: ":memory:"
```



### Multiple Database Setup


```yaml
entries:
  # Primary database
  - name: users_db
    kind: db.sql.postgres
    host: ${env:USERS_DB_HOST}
    port: 5432
    database: "users"
    username: ${env:USERS_DB_USER}
    password: ${env:app.secrets:users_db_password}
    lifecycle:
      auto_start: true

  # Analytics database
  - name: analytics_db
    kind: db.sql.mysql
    host: ${env:ANALYTICS_DB_HOST}
    port: 3306
    database: "analytics"
    username: ${env:ANALYTICS_DB_USER}
    password: ${env:app.secrets:analytics_db_password}
    lifecycle:
      auto_start: true

  # Local cache
  - name: cache
    kind: db.sql.sqlite
    file: "/var/cache/app.db"
    lifecycle:
      auto_start: true
```



## Runtime Registration


Databases can be registered at runtime using the [registry module](lua/core/registry.md).



## Lua API


See [SQL Module](lua/storage/sql.md) for query, transaction, and connection operations.



## See Also


- [SQL Module](lua/storage/sql.md) - Lua API reference
- [Store](system/store.md) - Key-value store backed by a `db.sql.*` database
- [Queue](system/queue.md) - SQL-backed queue handler
- [Change Data Capture](system/cdc.md) - Streaming row-level changes from a `db.sql.sqlite` or Postgres database



## Navigation

Previous: "Terminal" (system/terminal)
Next: "Change Data Capture" (system/cdc)
