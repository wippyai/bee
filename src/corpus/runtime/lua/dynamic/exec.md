# "Command Execution"

_Path: en/lua/dynamic/exec_

> "Execute external commands and shell scripts with full control over I/O streams."

## Table of Contents

- Command Execution

## Content

# Command Execution

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>
<secondary-label ref="permissions"/>

Execute external commands and shell scripts with full control over I/O streams.

For executor configuration, see [Executor](system/exec.md).



## Loading


```lua
local exec = require("exec")
```



## Acquiring an Executor


Get a process executor resource by ID:

```lua
local executor, err = exec.get("app:exec")
if err then
    return nil, err
end

-- Use executor
local proc = executor:exec("ls -la")
-- ...

-- Release when done
executor:release()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Resource ID |

**Returns:** `Executor, error`



## Creating a Process


Create a new process with the specified command:

```lua
-- Simple command
local proc, err = executor:exec("echo 'Hello, World!'")

-- With working directory
local proc = executor:exec("npm install", {
    work_dir = "/app/project"
})

-- With environment variables
local proc = executor:exec("python script.py", {
    work_dir = "/scripts",
    env = {
        PYTHONPATH = "/app/lib",
        DEBUG = "true",
        API_KEY = api_key
    }
})

-- Run shell script
local proc = executor:exec("./deploy.sh production", {
    work_dir = "/app/scripts",
    env = {
        DEPLOY_ENV = "production"
    }
})
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `cmd` | string | Executable and literal arguments |
| `options.work_dir` | string | Working directory |
| `options.env` | table | Environment variables |
| `options.pty` | table | Allocate a pseudo-terminal for the child |
| `options.process_group` | boolean | Start the child in its own process group so signals also reach descendants; unsupported on Windows |

**Returns:** `Process, error`

The process is created but not started.



### Command Parsing


`cmd` is split into an executable and literal arguments using shell-like quoting: single and double quotes group a word, and a backslash escapes the following character. There is no shell, so no variable expansion, globbing, pipes, or redirection happens. An unclosed quote returns `errors.INVALID`.

```lua
-- One argument containing a space, passed literally
local proc = executor:exec("grep 'hello world' notes.txt")

-- $HOME is passed as the five characters $HOME, not expanded
local proc = executor:exec("echo $HOME")
```

To use shell features, invoke a shell explicitly:

```lua
local proc = executor:exec("/bin/sh -c 'ls *.log | wc -l'")
```



### PTY Options


Allocating a PTY gives the child a real terminal: line editing, job control, and full-screen programs work as they do in a shell.

```lua
local proc = executor:exec("/bin/bash --noprofile --norc", {
    pty = {width = 100, height = 30, term = "xterm-256color"},
})
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `width` | number | 80 | Initial PTY columns, 1 to 65535 |
| `height` | number | 24 | Initial PTY rows, 1 to 65535 |
| `term` | string | none | Child `TERM` value |

Width times height may not exceed 262,144 cells. A PTY-backed process merges the child's output into a single terminal stream; drive it with [resize](#resize) and [attach_terminal](#attach_terminal) rather than the stdin/stdout pipe methods.



## start / wait


Start the process and wait for completion.

```lua
local proc = executor:exec("./build.sh")

local ok, err = proc:start()
if err then
    return nil, err
end

local exit_code, err = proc:wait()
if err then
    return nil, err
end

if exit_code ~= 0 then
    return nil, errors.new({ kind = errors.INTERNAL, message = "Build failed with exit code: " .. exit_code })
end
```



## stdout_stream / stderr_stream


Get streams to read process output.

```lua
local proc = executor:exec("./process-data.sh")

local stdout = proc:stdout_stream()
local stderr = proc:stderr_stream()

proc:start()

-- Read all stdout
local output = {}
while true do
    local chunk = stdout:read(4096)
    if not chunk then break end
    table.insert(output, chunk)
end
local result = table.concat(output)

-- Check for errors
local err_output = {}
while true do
    local chunk = stderr:read(4096)
    if not chunk then break end
    table.insert(err_output, chunk)
end

local exit_code = proc:wait()

stdout:close()
stderr:close()

if exit_code ~= 0 then
    return nil, errors.new({ kind = errors.INTERNAL, message = table.concat(err_output) })
end

return result
```



## write_stdin


Write data to process stdin.

```lua
local proc = executor:exec("head -n 3")
local stdout = proc:stdout_stream()

proc:start()

proc:write_stdin("banana\napple\ncherry\n")

local lines = stdout:read()

proc:wait()
stdout:close()
```

Each call writes the given bytes and returns. Call `close_stdin()` when the child
must see EOF:

```lua
local proc = assert(executor:exec("sort"))
local stdout = assert(proc:stdout_stream())
assert(proc:start())
assert(proc:write_stdin("banana\napple\n"))
assert(proc:close_stdin())
local sorted = assert(stdout:read())
```

`close_stdin()` is idempotent. Later writes fail because the input side is
closed. PTY-backed processes do not expose this pipe operation.



## done


Use `done()` to observe exit without consuming the process handle:

```lua
local proc = assert(executor:exec("./worker"))
assert(proc:start())
local exits = assert(proc:done())

local status, open = exits:receive()
if open then
    print(status.code, status.signal, status.error)
end
```

The returned channel delivers one exit record and then closes. Repeated calls
return the same channel. The record contains `code`, optional `signal`, and an
`error` only when the runtime could not observe the exit. A signal exit uses
`128 + signal` as its code. Unlike `wait()`, `done()` leaves the handle usable,
so streams, `signal()`, and `close()` remain available. `wait()` after delivery
returns the recorded code.



## signal / close


Send signals or release the process.

```lua
local proc = executor:exec("./long-running-server.sh")
proc:start()

-- ... later, need to stop it ...

-- Send SIGTERM and release the handle
proc:close()

-- Send SIGKILL and release the handle
proc:close(true)

-- Or send a specific signal and keep the handle
local SIGINT = 2
proc:signal(SIGINT)
```

`close(force?)` signals a started child with `SIGTERM`, or `SIGKILL` when `force` is true, then reaps it in the background so the call does not block. A child still running after a grace period is killed so the reap always completes. An unstarted handle is simply invalidated, and closing twice is not an error. When `process_group` is enabled, signals target the group and still reach descendants after the leader exits.

Streams acquired before reaping remain readable until their last writer closes,
including a descendant that inherited the pipe. After `close()`, process methods
report `process closed`; use `done()` when the exit matters and the handle must
remain usable.



## resize


Resize the PTY of a PTY-backed process. A pipe-backed process returns an error.

```lua
local ok, err = proc:resize(120, 40)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `width` | number | Columns, 1 to 65535 |
| `height` | number | Rows, 1 to 65535 |

**Returns:** `boolean, error`

Use it to set the initial geometry before handing the process to a terminal session. Once a session owns the process, send it a `resize` event instead.



## attach_terminal


Attach an unstarted PTY-backed process to the calling process's terminal and return a `TerminalSession`.

```lua
local exec = require("exec")
local tty = require("tty")

local executor = assert(exec.get("app:exec"))
local proc = assert(executor:exec("/bin/bash --noprofile --norc", {
    pty = {term = "xterm-256color"},
}))
local session = assert(proc:attach_terminal())
```

**Returns:** `TerminalSession, error`

The call consumes the process: the session becomes its sole lifecycle owner and the original handle can no longer be used. The session opens a surface on the current terminal port and owns PTY emulation, input encoding, resize, graceful and forced termination, and reaping. It needs a terminal port — a [terminal host](system/terminal.md) process, or a process spawned with a [viewport grant](lua/system/tty.md#viewport) — and fails when the port has no input controller or already has an open surface.



### TerminalSession


| Method | Returns | Description |
|--------|---------|-------------|
| `send(event)` | `boolean, error` | Forward one canonical TTY event to the child |
| `done()` | channel | Channel that fires once when the child finishes |
| `status()` | `string, error` | `"running"` or `"done"`, with the failure error when it failed |
| `close()` | `boolean, error` | Request termination of a running child |

`send` accepts the key, mouse, resize, focus, and paste records described in [TTY](lua/system/tty.md#event-types). Sending after the child has finished returns an error.

```lua
local channel = require("channel")

local events = assert(tty.events())
assert(tty.start())
local done = session:done()

while true do
    local selected = channel.select({
        events:case_receive(),
        done:case_receive(),
    })
    if not selected.ok or selected.channel == done then break end
    if selected.value.type == "close" then break end
    assert(session:send(selected.value))
end

assert(session:close())
```



## Permissions


Exec operations are subject to security policy evaluation.

| Action | Resource | Description |
|--------|----------|-------------|
| `exec.get` | Executor ID | Acquire an executor resource |
| `exec.run` | Command | Execute a specific command |

`exec.run` is evaluated against the raw command string, with the requested options as metadata:

| Key | Type | Description |
|-----|------|-------------|
| `work_dir` | string | Requested working directory, empty when unset |
| `env_names` | string[] | Names of the environment variables passed, sorted; values are not exposed |
| `pty.requested` | boolean | Whether a PTY was requested |
| `pty.width` | number | Resolved PTY columns, present when requested |
| `pty.height` | number | Resolved PTY rows, present when requested |
| `pty.term` | string | Requested `TERM` value, present when requested |

A policy can therefore allow plain commands while restricting the ones that ask for a terminal or a particular working directory.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Invalid ID | `errors.INVALID` | no |
| Permission denied | `errors.INVALID` | no |
| Process closed | `errors.INVALID` | no |
| Process not started | `errors.INVALID` | no |
| Already started | `errors.INVALID` | no |
| Unclosed quote in command | `errors.INVALID` | no |
| No PTY on the process | `errors.INVALID` | no |
| Terminal port unavailable | `errors.UNAVAILABLE` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Executor](system/exec.md) — executor configuration
- [TTY](lua/system/tty.md) — terminal events, surfaces, and viewports
- [Terminal UI](tutorials/tty.md) — a shell that hosts a PTY child in a viewport



## Navigation

Previous: "Dynamic Evaluation" (lua/dynamic/eval)
Next: "Expression Language" (lua/dynamic/expression)
