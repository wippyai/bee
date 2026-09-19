# "Terminal I/O"

_Path: en/lua/system/io_

> "Read from stdin and write to stdout/stderr for CLI applications."

## Table of Contents

- Terminal I/O

## Content

# Terminal I/O

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>

The `io` module reads from standard input and writes to standard output and standard error in terminal applications.

This is an API reference. Its snippets are isolated calls; a terminal process should propagate returned structured Lua errors when the result affects control flow.

<note>
This module is available only to processes running on a <a href="../../system/terminal.md">Terminal Host</a>, not to regular functions.
</note>



## Loading


```lua
local io = require("io")
```



## Writing to Stdout


Write values to standard output without a trailing newline:

```lua
local ok, err = io.write("text", "more")
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | any | Variable number of values to write (coerced to string) |

**Returns:** `boolean, error`



## Print with Newline


Write values to standard output, separated by tabs and followed by a newline:

```lua
io.print("value1", "value2", 123)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | any | Variable number of values to print |

**Returns:** `boolean, error`

After terminal context lookup succeeds, output write errors are ignored and the function returns `true`. A missing terminal context returns `nil, "no terminal context"`.



## Writing to Stderr


Write values to standard error, separated by tabs and followed by a newline:

```lua
io.eprint("Error:", message)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `...` | any | Variable number of values to print |

**Returns:** `boolean, error`

After terminal context lookup succeeds, output write errors are ignored and the function returns `true`. A missing terminal context returns `nil, "no terminal context"`.



## Reading Bytes


Read up to `n` bytes from standard input:

```lua
local data, err = io.read(1024)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `n` | integer | Number of bytes to read (default: 1024, values <= 0 become 1024) |

**Returns:** `string, error`. A successful read may return fewer than `n` bytes or an empty string.



## Reading a Line


Read one line from standard input:

```lua
local line, err = io.readline()
```

**Returns:** `string, error`. The trailing `\n` and `\r` are removed. EOF after partial input returns that partial line; EOF without input returns `nil` and a structured error.



## Raw Mode


Enable or disable raw terminal mode, which disables line buffering and echo:

```lua
local ok, err = io.raw(true)   -- enable
local ok, err = io.raw(false)  -- disable
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `enable` | boolean | `true` to enable, `false` to disable (default: `true`) |

**Returns:** `boolean, error`

Raw mode is reference-counted: each `io.raw(true)` call must be matched by an `io.raw(false)` call. The terminal returns to normal mode automatically when the process exits.



## Flushing Output


Flush the standard-output buffer:

```lua
local ok, err = io.flush()
```

**Returns:** `boolean, error`. The call is a successful no-op when standard output does not implement `Sync()`.



## Command Line Arguments


Retrieve the command-line arguments:

```lua
local args = io.args()
```

**Returns:** `string[]`

`io.args()` never fails. It returns an empty table when no terminal context is available.



## Errors


This module returns structured Lua errors. A missing terminal context uses `errors.UNAVAILABLE`; direct write/flush and invalid yield-response failures use `errors.INTERNAL`. Dispatcher-backed read, readline, and raw-mode failures preserve underlying error metadata when available. `io.args()` has no error return.



## Navigation

Previous: "Logging" (lua/system/logger)
Next: "Metrics & Telemetry" (lua/system/metrics)
