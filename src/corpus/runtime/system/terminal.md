# "Terminal"

_Path: en/system/terminal_

> "Terminal hosts execute Lua scripts with stdin/stdout/stderr access."

## Table of Contents

- Terminal

## Content

# Terminal


A `terminal.host` executes Lua scripts with standard input, output, and error streams. This page is a configuration reference; the Lua block is a handler fragment that assumes it is running through that host.

<note>
A terminal host runs exactly one process at a time. The process itself is a regular Lua process with access to terminal I/O context.
</note>



## Entry Kind


| Kind | Description |
|------|-------------|
| `terminal.host` | Terminal session host |



## Configuration


```yaml
- name: cli_host
  kind: terminal.host
  hide_logs: false
  lifecycle:
    auto_start: true
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `hide_logs` | bool | false | Stream logs to the event bus while suppressing downstream log propagation |



## Terminal Context


Scripts running on a terminal host receive a terminal context with:

- **stdin** — Standard input reader
- **stdout** — Standard output writer
- **stderr** — Standard error writer
- **args** — Command-line arguments



## Composable Terminals


The terminal a process sees is a port, not a device. That makes terminal ownership composable.

A process on a terminal host holds the physical port. It calls `tty.surface()` to take the port's presentation lease and publishes complete frames — it owns the whole screen.

A shell process hosts other processes by creating virtual terminals with `tty.viewport()`. It passes `viewport:grant()` to a child through the `terminal` spawn option; the child resolves that grant into an ordinary terminal port and runs unchanged, unaware that it is not attached to a device. The shell reads the child's frames with `viewport:snapshot()`, places them anywhere in its own layout, and translates input into the child's coordinates with `viewport:send()`.

```lua
local view = assert(tty.viewport({width = 78, height = 20}))
local child = assert(process.with_options({terminal = assert(view:grant())})
    :spawn_monitored("app:child", "app:workers"))
```

A grant is one-shot: process admission consumes it, a rejected start leaves it unresolved, and a host that cannot attach terminals rejects the spawn rather than dropping the option.

Byte-oriented programs join the same model through `exec`. A child allocates a PTY process and calls `process:attach_terminal()`; that adapter owns PTY emulation, input encoding, resize, and termination, and presents onto whichever port the child holds — physical or virtual.

```text
physical terminal -> shell surface -> viewport -> child process -> PTY proxy
```



## Lua API


The [IO Module](lua/system/io.md) provides line-oriented terminal operations:

```lua
local io = require("io")

local _, write_err = io.write("Enter name: ")
if write_err then return nil, write_err end

local name, read_err = io.readline()
if read_err then return nil, read_err end

local _, print_err = io.print("Hello, " .. name)
if print_err then return nil, print_err end

local args = io.args()
```

`io.write`, `io.print`, and `io.readline` return errors outside a terminal context. `io.args()` returns an empty table when no terminal context is available.

For raw input events, styled rendering, surfaces, and viewports, see [TTY](lua/system/tty.md). For PTY processes and terminal sessions, see [Command Execution](lua/dynamic/exec.md).



## See Also


- [Terminal I/O](lua/system/io.md) — stdin/stdout/stderr operations
- [TTY](lua/system/tty.md) — Input events, surfaces, canvases, and viewports
- [Command Execution](lua/dynamic/exec.md) — PTY processes and terminal sessions
- [Terminal UI](tutorials/tty.md) — build a shell that hosts a child in a viewport



## Navigation

Previous: "Process Groups" (system/process-groups)
Next: "Database System" (system/database)
