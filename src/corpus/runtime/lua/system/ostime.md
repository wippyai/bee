# "OS Time"

_Path: en/lua/system/ostime_

> "Standard Lua os time functions. Provides real wall-clock time for timestamps, date formatting, and time calculations."

## Table of Contents

- OS Time

## Content

# OS Time

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>

The global `os` table provides timestamps, date formatting, elapsed-time measurement, and time-difference calculations. In a workflow, current-time reads use the workflow's time reference; outside a workflow they use the system clock.

This is an API reference. Timestamp literals and formatted outputs are illustrative; current values depend on the runtime or workflow clock and timezone.



## Loading


The `os` table is global and does not require loading with `require`.

```lua
os.time()
os.date()
os.clock()
os.difftime()
```



## Getting Timestamps


Read a Unix timestamp in seconds since January 1, 1970 UTC:

```lua
-- Current timestamp
local now = os.time()  -- 1718462445

-- Specific date/time
local t = os.time({
    year = 2024,
    month = 12,
    day = 25,
    hour = 10,
    min = 30,
    sec = 0
})
```

**Signature:** `os.time([spec]) -> number`

**Parameters:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `year` | number | current year | Four-digit year (e.g., 2024) |
| `month` | number | current month | Month 1-12 |
| `day` | number | current day | Day of month 1-31 |
| `hour` | number | 0 | Hour 0-23 |
| `min` | number | 0 | Minute 0-59 |
| `sec` | number | 0 | Second 0-59 |

With no arguments, `os.time()` returns the current Unix timestamp.

When called with a table, missing fields use the defaults shown above. The `year`, `month`, and `day` fields use the current date when omitted.

```lua
-- Just date (time defaults to midnight)
os.time({year = 2024, month = 6, day = 15})

-- Partial (fills in current year/month)
os.time({day = 1})  -- first of current month
```



## Formatting Dates


Format a timestamp as a string or return its date fields in a table:

<code-block lang="lua">
local now = os.time()

-- Default format
os.date()  -- "Sat Jun 15 14:30:45 2024"

-- Custom format
os.date("%Y-%m-%d", now)           -- "2024-06-15"
os.date("%H:%M:%S", now)           -- "14:30:45"
os.date("%Y-%m-%dT%H:%M:%S", now)  -- "2024-06-15T14:30:45"

-- UTC time (prefix format with !)
os.date("!%Y-%m-%d %H:%M:%S", now)  -- UTC instead of local

-- Date table
local t = os.date("*t", now)
</code-block>

**Signature:** `os.date([format], [timestamp]) -> string | table`

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `format` | string | `"%c"` | Format string, `"*t"` for table |
| `timestamp` | number | current time | Unix timestamp to format |



### Format Specifiers


| Code | Output | Example |
|------|--------|---------|
| `%Y` | 4-digit year | 2024 |
| `%y` | 2-digit year | 24 |
| `%m` | Month (01-12) | 06 |
| `%d` | Day (01-31) | 15 |
| `%H` | Hour 24h (00-23) | 14 |
| `%I` | Hour 12h (01-12) | 02 |
| `%M` | Minute (00-59) | 30 |
| `%S` | Second (00-59) | 45 |
| `%p` | AM/PM | PM |
| `%A` | Weekday name | Saturday |
| `%a` | Weekday short | Sat |
| `%B` | Month name | June |
| `%b` | Month short | Jun |
| `%w` | Weekday (0-6, Sunday=0) | 6 |
| `%j` | Day of year (001-366) | 167 |
| `%U` | ISO 8601 week number (01-53, week starts Monday) | 24 |
| `%W` | ISO 8601 week number (01-53, week starts Monday) | 24 |
| `%z` | Timezone offset | -0700 |
| `%Z` | Timezone name | PDT |
| `%c` | Full date/time | Sat Jun 15 14:30:45 2024 |
| `%x` | Date only | 06/15/24 |
| `%X` | Time only | 14:30:45 |
| `%%` | Literal % | % |



### Date Table


When the format is `"*t"`, `os.date()` returns a table:

```lua
local t = os.date("*t")
```

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `year` | number | Four-digit year | 2024 |
| `month` | number | Month (1-12) | 6 |
| `day` | number | Day of month (1-31) | 15 |
| `hour` | number | Hour (0-23) | 14 |
| `min` | number | Minute (0-59) | 30 |
| `sec` | number | Second (0-59) | 45 |
| `wday` | number | Weekday (1-7, Sunday=1) | 7 |
| `yday` | number | Day of year (1-366) | 167 |
| `isdst` | boolean | `true` when the zone's UTC offset is nonzero in this release; not a reliable DST indicator | false |

Use `"!*t"` for UTC date table.



## Measuring Elapsed Time


Read the seconds between the current runtime time reference and the OS-time module's initialization time:

```lua
local start = os.clock()

-- do work
for i = 1, 1000000 do end

local elapsed = os.clock() - start
print(string.format("Took %.3f seconds", elapsed))
```

**Signature:** `os.clock() -> number`

Unlike standard Lua's CPU-time definition, this implementation is based on elapsed time. In workflows, it uses the workflow time reference.



## Time Difference


Calculate the difference between two timestamps in seconds:

```lua
local t1 = os.time({year = 2024, month = 1, day = 1})
local t2 = os.time({year = 2024, month = 12, day = 31})

local diff = os.difftime(t2, t1)  -- t2 - t1
local days = diff / 86400
print(days)  -- 365
```

**Signature:** `os.difftime(t2, t1) -> number`

| Parameter | Type | Description |
|-----------|------|-------------|
| `t2` | number | Later timestamp |
| `t1` | number | Earlier timestamp |

The result is `t2 - t1` in seconds and is negative when `t1 > t2`.



## Platform Constant


The `os.platform` constant identifies the runtime:

```lua
os.platform  -- "wippy"
```



## Navigation

Previous: "Metrics & Telemetry" (lua/system/metrics)
Next: "TTY" (lua/system/tty)
