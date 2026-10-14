# "SQL Database"

_Path: en/lua/storage/sql_

> "Execute SQL queries against PostgreSQL, MySQL, and SQLite databases. Features include parameterized queries, transactions, prepared statements, and a…"

## Table of Contents

- SQL Database

## Content

# SQL Database

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>
<secondary-label ref="permissions"/>

The `sql` module runs queries against configured PostgreSQL, MySQL, and SQLite databases. It supports parameterized queries, transactions, prepared statements, and query builders.

This page is an API reference. Its snippets assume a configured database, permission to acquire it, and any tables named by the query. They illustrate individual calls rather than a standalone application. The combined recipe at the end states its additional schema and driver assumptions.

For database configuration, see [Database](system/database.md).



## Loading


```lua
local sql = require("sql")
```



## `sql.get`


Acquire a database connection from the resource registry:

```lua
local db, err = sql.get("app.db:main")
if err then
    return nil, err
end

local function finish(value, primary_err)
    local _, release_err = db:release()
    if primary_err then return nil, primary_err end
    if release_err then return nil, release_err end
    return value
end

local rows, err = db:query("SELECT * FROM users WHERE active = ?", {1})
if err then
    return finish(nil, err)
end

return finish(rows)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Resource ID (e.g., "app.db:main") |

**Returns:** `DB, error`

<note>
Database leases are released during execution-frame cleanup. Call `db:release()` explicitly when database work finishes, especially in long-running operations.
</note>

<note>
Placeholders are passed to the database driver unchanged; the runtime does not rewrite them. SQLite and MySQL use `?`, PostgreSQL uses `$1, $2` — write them in the form your driver expects. The examples below use `?` (SQLite/MySQL). For queries that target more than one engine, build them with the [query builder](#query-builder): `run_with` rewrites placeholders to `$1, $2` when the handle is PostgreSQL, and `to_sql` uses the builder's `placeholder_format`.
</note>



### Database Types


```lua
sql.type.POSTGRES    -- "postgres"
sql.type.MYSQL       -- "mysql"
sql.type.SQLITE      -- "sqlite"
sql.type.UNKNOWN     -- "unknown"
```



### Isolation Levels


```lua
sql.isolation.DEFAULT           -- "default"
sql.isolation.READ_UNCOMMITTED  -- "read_uncommitted"
sql.isolation.READ_COMMITTED    -- "read_committed"
sql.isolation.WRITE_COMMITTED   -- "write_committed"
sql.isolation.REPEATABLE_READ   -- "repeatable_read"
sql.isolation.SERIALIZABLE      -- "serializable"
```



### NULL Value


```lua
local insert = sql.builder.insert("users")
    :columns("name", "email")
    :values("alice", sql.NULL)
```



### `sql.as.int`


Coerce a value to the SQL integer type.

```lua
local value = sql.as.int(42)
```

**Returns:** `userdata`



### `sql.as.float`


Coerce a value to the SQL float type.

```lua
local value = sql.as.float(19.99)
```

**Returns:** `userdata`



### `sql.as.text`


Coerce a value to the SQL text type.

```lua
local value = sql.as.text("hello")
```

**Returns:** `userdata`



### `sql.as.binary`


Coerce a value to the SQL binary type.

```lua
local value = sql.as.binary("binary data")
```

**Returns:** `userdata`



### `sql.as.null`


Return the SQL `NULL` marker.

```lua
local value = sql.as.null()
```

**Returns:** `userdata`



### `sql.builder.select`


Create a `SELECT` query builder.

```lua
local query = sql.builder.select("id", "name")
    :from("users")
    :where({active = 1})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `columns` | ...string | Column names (optional) |

**Returns:** `SelectBuilder`



### `sql.builder.insert`


Create an `INSERT` query builder.

```lua
local query = sql.builder.insert("users")
    :columns("name", "email")
    :values("alice", "alice@example.com")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name (optional) |

**Returns:** `InsertBuilder`



### `sql.builder.update`


Create an `UPDATE` query builder.

```lua
local query = sql.builder.update("users")
    :set("status", "active")
    :where({id = 123})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name (optional) |

**Returns:** `UpdateBuilder`



### `sql.builder.delete`


Create a `DELETE` query builder.

```lua
local query = sql.builder.delete("users")
    :where({active = 0})
    :limit(100)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name (optional) |

**Returns:** `DeleteBuilder`



### `sql.builder.expr`


Create a raw SQL expression for use in `WHERE` or `HAVING` clauses.

```lua
local expr = sql.builder.expr("score BETWEEN ? AND ?", 80, 90)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL expression with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `Sqlizer`



### `sql.builder.eq`


Create equality conditions from a table.

```lua
local cond = sql.builder.eq({active = 1, status = "open"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.not_eq`


Create inequality conditions from a table.

```lua
local cond = sql.builder.not_eq({status = "closed"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.lt`


Create less-than conditions from a table.

```lua
local cond = sql.builder.lt({age = 18})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.lte`


Create less-than-or-equal conditions from a table.

```lua
local cond = sql.builder.lte({price = 100})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.gt`


Create greater-than conditions from a table.

```lua
local cond = sql.builder.gt({score = 80})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.gte`


Create greater-than-or-equal conditions from a table.

```lua
local cond = sql.builder.gte({age = 21})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.like`


Create `LIKE` conditions from a table.

```lua
local cond = sql.builder.like({name = "john%"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.not_like`


Create `NOT LIKE` conditions from a table.

```lua
local cond = sql.builder.not_like({email = "%@spam.com"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `Sqlizer`



### `sql.builder.and_`


Combine multiple conditions with `AND`.

```lua
local cond = sql.builder.and_({
    sql.builder.eq({active = 1}),
    sql.builder.gt({score = 80})
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `conditions` | table | Array of Sqlizer or table conditions |

**Returns:** `Sqlizer`



### `sql.builder.or_`


Combine multiple conditions with `OR`.

```lua
local cond = sql.builder.or_({
    sql.builder.eq({status = "pending"}),
    sql.builder.eq({status = "active"})
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `conditions` | table | Array of Sqlizer or table conditions |

**Returns:** `Sqlizer`



## sqlizer:to_sql


Generates the SQL fragment and bind arguments of a condition.

```lua
local frag, args = sql.builder.eq({active = 1}):to_sql()
```

**Returns:** `string, table`



## builder.question


Use `?` placeholders (default). This format is also available as `sql.builder.default_placeholder`.

```lua
local query = sql.builder.select("*")
    :from("users")
    :placeholder_format(sql.builder.question)
```



### `sql.builder.dollar`


Use `$1, $2, ...` placeholders.

```lua
local query = sql.builder.select("*")
    :from("users")
    :placeholder_format(sql.builder.dollar)
```



### `sql.builder.at`


Use `@p1, @p2, ...` placeholders (SQL Server style). Pass this format to `placeholder_format` like the formats above.



### `sql.builder.colon`


Use `:1, :2, ...` placeholders. Pass this format to `placeholder_format` like the formats above.



## Connection Methods


A connection handle returned by `sql.get()` provides query, transaction, statement, and pool operations.



### `db:type`


Return the database type constant.

```lua
local dbtype, err = db:type()
```

**Returns:** `string, error`



### `db:query`


Run a `SELECT` query and return its rows.

```lua
local rows, err = db:query("SELECT id, name FROM users WHERE active = ?", {1})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL query with ? placeholders |
| `params` | table | Array of bind parameters (optional) |

**Returns:** `table[], error`



### `db:execute`


Run an `INSERT`, `UPDATE`, or `DELETE` statement.

```lua
local result, err = db:execute("INSERT INTO users (name) VALUES (?)", {"alice"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL statement with ? placeholders |
| `params` | table | Array of bind parameters (optional) |

**Returns:** `table, error`

Returns table with fields:
- `last_insert_id` - Last inserted ID
- `rows_affected` - Number of rows affected



### `db:prepare`


Create a prepared statement for repeated execution.

```lua
local stmt, err = db:prepare("SELECT * FROM users WHERE id = ?")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL with ? placeholders |

**Returns:** `Statement, error`



### `db:begin`


Begin a database transaction.

```lua
local tx, err = db:begin({
    isolation = sql.isolation.SERIALIZABLE,
    read_only = false
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `options` | table | Transaction options (optional) |

Options table fields:
- `isolation` - Isolation level from sql.isolation.* (default: DEFAULT)
- `read_only` - Read-only transaction flag (default: false)

**Returns:** `Transaction, error`



### `db:release`


Release the database resource back to the pool.

```lua
local ok, err = db:release()
```

**Returns:** `boolean, error`

The operation is idempotent.



### `db:stats`


Return connection-pool statistics.

```lua
local stats, err = db:stats()
```

**Returns:** `table, error`

Returns table with fields:
- `max_open_connections` - Max allowed open connections
- `open_connections` - Current open connections
- `in_use` - Connections currently in use
- `idle` - Idle connections in pool
- `wait_count` - Total connection wait count
- `wait_duration` - Total wait duration
- `max_idle_closed` - Connections closed due to max idle
- `max_idle_time_closed` - Connections closed due to idle timeout
- `max_lifetime_closed` - Connections closed due to max lifetime



## Prepared Statements


A prepared statement returned by `db:prepare()` can be queried or executed repeatedly.



### `stmt:query`


Run the prepared statement as a `SELECT` query.

```lua
local rows, err = stmt:query({123})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `params` | table | Array of bind parameters (optional) |

**Returns:** `table[], error`



### `stmt:execute`


Run the prepared statement as an `INSERT`, `UPDATE`, or `DELETE` statement.

```lua
local result, err = stmt:execute({"alice"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `params` | table | Array of bind parameters (optional) |

**Returns:** `table, error`

Returns table with fields:
- `last_insert_id` - Last inserted ID
- `rows_affected` - Number of rows affected



### `stmt:close`


Close the prepared statement.

```lua
local ok, err = stmt:close()
```

**Returns:** `boolean, error`



## Transactions


A transaction returned by `db:begin()` provides query, statement, savepoint, commit, and rollback operations.

An active transaction is rolled back automatically during execution-frame cleanup. Commit or roll it back explicitly as soon as its work is complete.



### `tx:db_type`


Return the database type constant.

```lua
local dbtype, err = tx:db_type()
```

**Returns:** `string, error`



### `tx:query`


Run a `SELECT` query within the transaction.

```lua
local rows, err = tx:query("SELECT id, name FROM users WHERE active = ?", {1})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL query with ? placeholders |
| `params` | table | Array of bind parameters (optional) |

**Returns:** `table[], error`



### `tx:execute`


Run an `INSERT`, `UPDATE`, or `DELETE` statement within the transaction.

```lua
local result, err = tx:execute("INSERT INTO users (name) VALUES (?)", {"alice"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL statement with ? placeholders |
| `params` | table | Array of bind parameters (optional) |

**Returns:** `table, error`

Returns table with fields:
- `last_insert_id` - Last inserted ID
- `rows_affected` - Number of rows affected



### `tx:prepare`


Create a prepared statement within the transaction.

```lua
local stmt, err = tx:prepare("SELECT * FROM users WHERE id = ?")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL with ? placeholders |

**Returns:** `Statement, error`



### `tx:commit`


Commit the transaction.

```lua
local ok, err = tx:commit()
```

**Returns:** `boolean, error`



### `tx:rollback`


Roll back the transaction.

```lua
local ok, err = tx:rollback()
```

**Returns:** `boolean, error`



### `tx:savepoint`


Create a named savepoint within the transaction.

```lua
local ok, err = tx:savepoint("sp1")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Savepoint name (alphanumeric and underscore only) |

**Returns:** `boolean, error`



### `tx:rollback_to`


Roll back to a named savepoint.

```lua
local ok, err = tx:rollback_to("sp1")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Savepoint name |

**Returns:** `boolean, error`



### `tx:release`


Release a savepoint.

```lua
local ok, err = tx:release("sp1")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Savepoint name |

**Returns:** `boolean, error`



## SELECT Builder


Build a `SELECT` query one clause at a time.



### `select:from`


Set the `FROM` clause.

```lua
local query = sql.builder.select("id", "name"):from("users")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name |

**Returns:** `SelectBuilder`



### `select:join`


Add a `JOIN` clause.

```lua
local query = sql.builder.select("*")
    :from("users")
    :join("orders ON orders.user_id = users.id")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `join` | string | JOIN clause with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `SelectBuilder`



### `select:left_join`


Add a `LEFT JOIN` clause.

```lua
local query = sql.builder.select("*")
    :from("users")
    :left_join("orders ON orders.user_id = users.id")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `join` | string | JOIN clause with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `SelectBuilder`



### `select:right_join`


Add a `RIGHT JOIN` clause.

```lua
local query = sql.builder.select("*")
    :from("users")
    :right_join("orders ON orders.user_id = users.id")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `join` | string | JOIN clause with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `SelectBuilder`



### `select:inner_join`


Add an `INNER JOIN` clause.

```lua
local query = sql.builder.select("*")
    :from("users")
    :inner_join("orders ON orders.user_id = users.id")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `join` | string | JOIN clause with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `SelectBuilder`



### `select:where`


Add a `WHERE` condition.

```lua
local query = sql.builder.select("*")
    :from("users")
    :where({active = 1})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `condition` | string\|table\|Sqlizer | WHERE condition |
| `args` | ...any | Bind arguments (optional, when using string) |

The method accepts three formats:
- String: `where("status = ?", "active")`
- Table: `where({status = "active"})`
- Sqlizer: `where(sql.builder.gt({score = 80}))`

**Returns:** `SelectBuilder`



### `select:order_by`


Add an `ORDER BY` clause.

```lua
local query = sql.builder.select("*")
    :from("users")
    :order_by("name ASC", "created_at DESC")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `columns` | ...string | Column names with optional ASC/DESC |

**Returns:** `SelectBuilder`



### `select:group_by`


Add a `GROUP BY` clause.

```lua
local query = sql.builder.select("status", "COUNT(*)")
    :from("users")
    :group_by("status")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `columns` | ...string | Column names |

**Returns:** `SelectBuilder`



### `select:having`


Add a `HAVING` condition.

```lua
local query = sql.builder.select("status", "COUNT(*) as cnt")
    :from("users")
    :group_by("status")
    :having(sql.builder.gt({cnt = 10}))
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `condition` | string\|table\|Sqlizer | HAVING condition |
| `args` | ...any | Bind arguments (optional, when using string) |

**Returns:** `SelectBuilder`



### `select:limit`


Set the `LIMIT` value.

```lua
local query = sql.builder.select("*")
    :from("users")
    :limit(10)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `n` | integer | Limit value |

**Returns:** `SelectBuilder`



### `select:offset`


Set the `OFFSET` value.

```lua
local query = sql.builder.select("*")
    :from("users")
    :offset(20)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `n` | integer | Offset value |

**Returns:** `SelectBuilder`



### `select:columns`


Add columns to the `SELECT` list.

```lua
local query = sql.builder.select():columns("id", "name", "email")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `columns` | ...string | Column names |

**Returns:** `SelectBuilder`



### `select:distinct`


Add the `DISTINCT` modifier.

```lua
local query = sql.builder.select("status")
    :from("users")
    :distinct()
```

**Returns:** `SelectBuilder`



### `select:suffix`


Add an SQL suffix.

```lua
local query = sql.builder.select("*")
    :from("users")
    :suffix("FOR UPDATE")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL suffix with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `SelectBuilder`



### `select:placeholder_format`


Set the placeholder format.

```lua
local query = sql.builder.select("*")
    :from("users")
    :placeholder_format(sql.builder.dollar)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `format` | userdata | Placeholder format (sql.builder.*) |

**Returns:** `SelectBuilder`



### `select:to_sql`


Generate the SQL string and bind arguments.

```lua
local sql_str, args = query:to_sql()
```

**Returns:** `string, table` on success; `nil, error` for an invalid builder state



### `select:run_with`


Create an executor for the query.

```lua
local executor, err = query:run_with(db)
if err then
    return nil, err
end
local rows, err = executor:query()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `db` | DB\|Transaction | Database or transaction handle |

**Returns:** `QueryExecutor, error`



## INSERT Builder


Build an `INSERT` query one clause at a time.



### `insert:into`


Set the table name.

```lua
local query = sql.builder.insert():into("users")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name |

**Returns:** `InsertBuilder`



### `insert:columns`


Set the column names.

```lua
local query = sql.builder.insert("users"):columns("name", "email")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `columns` | ...string | Column names |

**Returns:** `InsertBuilder`



### `insert:values`


Add row values.

```lua
local query = sql.builder.insert("users")
    :columns("name", "email")
    :values("alice", "alice@example.com")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `values` | ...any | Row values |

**Returns:** `InsertBuilder`



### `insert:set_map`


Set columns and values from a table.

```lua
local query = sql.builder.insert("users")
    :set_map({name = "alice", email = "alice@example.com"})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs |

**Returns:** `InsertBuilder`



### `insert:select`


Insert rows from a `SELECT` query.

```lua
local select_query = sql.builder.select("name", "email"):from("temp_users")
local query = sql.builder.insert("users")
    :columns("name", "email")
    :select(select_query)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | SelectBuilder | SELECT query |

**Returns:** `InsertBuilder`



### `insert:prefix`


Add an SQL prefix.

```lua
local query = sql.builder.insert("users")
    :prefix("/* audit import */")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL prefix with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `InsertBuilder`



### `insert:suffix`


Add an SQL suffix.

```lua
local query = sql.builder.insert("users")
    :columns("name")
    :values("alice")
    :suffix("RETURNING id")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL suffix with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `InsertBuilder`



### `insert:options`


Add `INSERT` options.

```lua
local query = sql.builder.insert("users")
    :options("DELAYED", "IGNORE")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `options` | ...string | INSERT options |

**Returns:** `InsertBuilder`



### `insert:placeholder_format`


Set the placeholder format.

```lua
local query = sql.builder.insert("users")
    :placeholder_format(sql.builder.dollar)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `format` | userdata | Placeholder format (sql.builder.*) |

**Returns:** `InsertBuilder`



### `insert:to_sql`


Generate the SQL string and bind arguments.

```lua
local sql_str, args = query:to_sql()
```

**Returns:** `string, table` on success; `nil, error` for an invalid builder state



### `insert:run_with`


Create an executor for the query.

```lua
local executor, err = query:run_with(db)
if err then
    return nil, err
end
local result, err = executor:exec()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `db` | DB\|Transaction | Database or transaction handle |

**Returns:** `QueryExecutor, error`



## UPDATE Builder


Build an `UPDATE` query one clause at a time.



### `update:table`


Set the table name.

```lua
local query = sql.builder.update():table("users")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name |

**Returns:** `UpdateBuilder`



### `update:set`


Set a column value.

```lua
local query = sql.builder.update("users")
    :set("status", "active")
    :set("updated_at", sql.builder.expr("NOW()"))
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `column` | string | Column name |
| `value` | any | Column value |

**Returns:** `UpdateBuilder`



### `update:set_map`


Set multiple columns from a table.

```lua
local query = sql.builder.update("users")
    :set_map({status = "active", login_count = 0})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `map` | table | {column = value} pairs; values are plain values, `sql.NULL`, or `sql.as.*` (use `set` for expressions) |

**Returns:** `UpdateBuilder`



### `update:where`


Add a `WHERE` condition.

```lua
local query = sql.builder.update("users")
    :set("status", "active")
    :where({id = 123})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `condition` | string\|table\|Sqlizer | WHERE condition |
| `args` | ...any | Bind arguments (optional, when using string) |

**Returns:** `UpdateBuilder`



### `update:order_by`


Add an `ORDER BY` clause.

```lua
local query = sql.builder.update("users")
    :set("rank", 1)
    :order_by("score DESC")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `columns` | ...string | Column names with optional ASC/DESC |

**Returns:** `UpdateBuilder`



### `update:limit`


Set the `LIMIT` value.

```lua
local query = sql.builder.update("users")
    :set("status", "active")
    :limit(10)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `n` | integer | Limit value |

**Returns:** `UpdateBuilder`



### `update:offset`


Set the `OFFSET` value.

```lua
local query = sql.builder.update("users")
    :set("status", "active")
    :offset(5)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `n` | integer | Offset value |

**Returns:** `UpdateBuilder`



### `update:suffix`


Add an SQL suffix.

```lua
local query = sql.builder.update("users")
    :set("status", "active")
    :suffix("RETURNING id")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL suffix with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `UpdateBuilder`



### `update:from`


Add a `FROM` clause.

```lua
local query = sql.builder.update("users")
    :set("status", "active")
    :from("other_table")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name |

**Returns:** `UpdateBuilder`



### `update:from_select`


Update rows from a `SELECT` query.

```lua
local select_query = sql.builder.select("*"):from("temp_users")
local query = sql.builder.update("users")
    :set("status", "active")
    :from_select(select_query, "t")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | SelectBuilder | SELECT query |
| `alias` | string | Table alias |

**Returns:** `UpdateBuilder`



### `update:placeholder_format`


Set the placeholder format.

```lua
local query = sql.builder.update("users")
    :placeholder_format(sql.builder.dollar)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `format` | userdata | Placeholder format (sql.builder.*) |

**Returns:** `UpdateBuilder`



### `update:to_sql`


Generate the SQL string and bind arguments.

```lua
local sql_str, args = query:to_sql()
```

**Returns:** `string, table` on success; `nil, error` for an invalid builder state



### `update:run_with`


Create an executor for the query.

```lua
local executor, err = query:run_with(db)
if err then
    return nil, err
end
local result, err = executor:exec()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `db` | DB\|Transaction | Database or transaction handle |

**Returns:** `QueryExecutor, error`



## DELETE Builder


Build a `DELETE` query one clause at a time.



### `delete:from`


Set the table name.

```lua
local query = sql.builder.delete():from("users")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `table` | string | Table name |

**Returns:** `DeleteBuilder`



### `delete:where`


Add a `WHERE` condition.

```lua
local query = sql.builder.delete("users")
    :where({active = 0})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `condition` | string\|table\|Sqlizer | WHERE condition |
| `args` | ...any | Bind arguments (optional, when using string) |

**Returns:** `DeleteBuilder`



### `delete:order_by`


Add an `ORDER BY` clause.

```lua
local query = sql.builder.delete("users")
    :where({active = 0})
    :order_by("created_at ASC")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `columns` | ...string | Column names with optional ASC/DESC |

**Returns:** `DeleteBuilder`



### `delete:limit`


Set the `LIMIT` value.

```lua
local query = sql.builder.delete("users")
    :where({active = 0})
    :limit(100)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `n` | integer | Limit value |

**Returns:** `DeleteBuilder`



### `delete:offset`


Set the `OFFSET` value.

```lua
local query = sql.builder.delete("users")
    :where({active = 0})
    :offset(10)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `n` | integer | Offset value |

**Returns:** `DeleteBuilder`



### `delete:suffix`


Add an SQL suffix.

```lua
local query = sql.builder.delete("users")
    :where({active = 0})
    :suffix("RETURNING id")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `sql` | string | SQL suffix with ? placeholders |
| `args` | ...any | Bind arguments (optional) |

**Returns:** `DeleteBuilder`



### `delete:placeholder_format`


Set the placeholder format.

```lua
local query = sql.builder.delete("users")
    :placeholder_format(sql.builder.dollar)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `format` | userdata | Placeholder format (sql.builder.*) |

**Returns:** `DeleteBuilder`



### `delete:to_sql`


Generate the SQL string and bind arguments.

```lua
local sql_str, args = query:to_sql()
```

**Returns:** `string, table` on success; `nil, error` for an invalid builder state



### `delete:run_with`


Create an executor for the query.

```lua
local executor, err = query:run_with(db)
if err then
    return nil, err
end
local result, err = executor:exec()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `db` | DB\|Transaction | Database or transaction handle |

**Returns:** `QueryExecutor, error`



## Executing Queries


The query executor runs builder-generated queries.



### `executor:query`


Run the query and return rows for a `SELECT` statement.

```lua
local rows, err = executor:query()
```

**Returns:** `table[], error`



### `executor:exec`


Run the query and return the result of an `INSERT`, `UPDATE`, or `DELETE` statement.

```lua
local result, err = executor:exec()
```

**Returns:** `table, error`

Returns table with fields:
- `last_insert_id` - Last inserted ID
- `rows_affected` - Number of rows affected



### `executor:to_sql`


Return the generated SQL and arguments without executing the query.

```lua
local sql_str, args = executor:to_sql()
```

**Returns:** `string, table`



## Permissions


Database access is subject to security policy evaluation.

| Action | Resource | Description |
|--------|----------|-------------|
| `db.get` | Database ID | Acquire database connection |



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty resource ID | `errors.INVALID` | no |
| Permission denied | `errors.PERMISSION_DENIED` | no |
| Resource not found | `errors.NOT_FOUND` | no |
| Resource not database | `errors.INVALID` | no |
| Invalid parameters | `errors.INVALID` | no |
| SQL syntax error | `errors.UNKNOWN` | nil |
| Statement closed | `errors.INVALID` | no |
| Transaction not active | `errors.INVALID` | no |
| Invalid savepoint name | `errors.INVALID` | no |
| Query execution error | `errors.UNKNOWN` | nil |

See [Error Handling](lua/core/errors.md) for working with errors.



## Combined Partial Recipe


This recipe assumes `app.db:main` is a configured SQLite or MySQL database and already contains `users`, `orders`, and `logs` tables with the referenced columns. It uses `?` placeholders; use `$1`, `$2`, and so on for a PostgreSQL resource. Returned rows depend on the application's data. The surrounding application supplies `report_cleanup_error(err)` so rollback or close failures are observable without replacing the initiating operation error.

```lua
local sql = require("sql")

local db, err = sql.get("app.db:main")
if err then return nil, err end

local function finish(value, primary_err)
    local _, release_err = db:release()
    if primary_err then return nil, primary_err end
    if release_err then return nil, release_err end
    return value
end

-- Direct query
local users, err = db:query("SELECT id, name FROM users WHERE active = ?", {1})
if err then
    return finish(nil, err)
end

for _, user in ipairs(users) do
    print(user.id, user.name)
end

-- Builder pattern
local query = sql.builder.select("u.id", "u.name", "COUNT(o.id) as order_count")
    :from("users u")
    :left_join("orders o ON o.user_id = u.id")
    :where(sql.builder.and_({
        sql.builder.eq({["u.active"] = 1}),
        sql.builder.gte({["u.score"] = 80})
    }))
    :group_by("u.id", "u.name")
    :having(sql.builder.gt({["COUNT(o.id)"] = 0}))
    :order_by("order_count DESC")
    :limit(10)

local executor, build_err = query:run_with(db)
if build_err then
    return finish(nil, build_err)
end
local results, err = executor:query()
if err then
    return finish(nil, err)
end

-- Transaction
local tx, err = db:begin({isolation = sql.isolation.SERIALIZABLE})
if err then
    return finish(nil, err)
end

local _, err = tx:execute("INSERT INTO users (name) VALUES (?)", {"alice"})
if err then
    local _, rollback_err = tx:rollback()
    if rollback_err then report_cleanup_error(rollback_err) end
    return finish(nil, err)
end

local _, commit_err = tx:commit()
if commit_err then
    return finish(nil, commit_err)
end

-- Prepared statements
local stmt, err = db:prepare("INSERT INTO logs (message, level) VALUES (?, ?)")
if err then
    return finish(nil, err)
end

for i = 1, 3 do
    local _, err = stmt:execute({"log message " .. i, "info"})
    if err then
        local _, close_err = stmt:close()
        if close_err then report_cleanup_error(close_err) end
        return finish(nil, err)
    end
end

local _, close_err = stmt:close()
if close_err then
    return finish(nil, close_err)
end

return finish({users = users, ranked_users = results})
```



## Navigation

Previous: "HTML Sanitization" (lua/http/html)
Next: "Key-Value Store" (lua/storage/store)
