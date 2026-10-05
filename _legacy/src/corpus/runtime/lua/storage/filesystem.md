# "Filesystem"

_Path: en/lua/storage/filesystem_

> "Read, write, and manage files within sandboxed filesystem volumes."

## Table of Contents

- Filesystem

## Content

# Filesystem

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>
<secondary-label ref="permissions"/>

The `fs` module reads, writes, and manages files within configured filesystem volumes.

This page is an API reference. Its snippets assume a configured volume and permission to acquire it. Each block is an isolated operation or partial recipe; application values and callbacks such as `config`, `message`, `process`, and `report_cleanup_error` must already exist. `report_cleanup_error(err)` records a close failure without replacing an operation error that already occurred.

For filesystem configuration, see [Filesystem](system/filesystem.md).



## Loading


```lua
local fs = require("fs")
```



## Acquiring a Volume


Acquire a filesystem volume by registry ID:

```lua
local vol, err = fs.get("app:storage")
if err then
    return nil, err
end

local content, read_err = vol:readfile("/config.json")
if read_err then return nil, read_err end
return content
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Volume registry ID |

**Returns:** `FS, error`

<note>
Volumes do not require explicit release. The system manages them, and a volume becomes unavailable when its filesystem is detached from the registry.
</note>



## Reading Files


Read an entire file:

```lua
local json = require("json")

local vol, get_err = fs.get("app:config")
if get_err then return nil, get_err end

local data, err = vol:readfile("/settings.json")
if err then
    return nil, err
end

local config, decode_err = json.decode(data)
if decode_err then return nil, decode_err end
return config
```

Use `open()` to stream a large file:

```lua
local errors = require("errors")

local file, err = vol:open("/data/large.csv", "r")
if err then
    return nil, err
end

while true do
    local chunk, err = file:read(65536)
    if err then
        if err:kind() == errors.NOT_FOUND then
            break -- EOF
        end
        local _, close_err = file:close()
        if close_err then report_cleanup_error(close_err) end
        return nil, err
    end
    process(chunk)
end

local _, close_err = file:close()
if close_err then return nil, close_err end
```



## Writing Files


Write a string or reader-backed stream to a file:

```lua
local json = require("json")

local vol, get_err = fs.get("app:data")
if get_err then return nil, get_err end

-- Overwrite (default)
local encoded, encode_err = json.encode(config)
if encode_err then return nil, encode_err end
local _, write_err = vol:writefile("/config.json", encoded)
if write_err then return nil, write_err end

-- Append
local _, append_err = vol:writefile("/logs/app.log", message .. "\n", "a")
if append_err then return nil, append_err end

-- Exclusive write (fails if exists)
local ok, err = vol:writefile("/lock.pid", tostring(pid), "wx")
if err then return nil, err end

-- Copy from an open file or another reader-backed value
local source, err = vol:open("/incoming/report.csv", "r")
if err then
    return nil, err
end
local copied, err = vol:writefile("/archive/report.csv", source)
local _, close_err = source:close()
if err then
    if close_err then report_cleanup_error(close_err) end
    return nil, err
end
if close_err then return nil, close_err end
return copied
```

| Mode | Description |
|------|-------------|
| `"w"` | Overwrite (default) |
| `"a"` | Append |
| `"wx"` | Exclusive write (fails if file exists) |

Use a file handle for streaming writes:

```lua
local file, open_err = vol:open("/output/report.txt", "w")
if open_err then return nil, open_err end
local _, header_err = file:write("Header\n")
if header_err then
    local _, close_err = file:close()
    if close_err then report_cleanup_error(close_err) end
    return nil, header_err
end
local _, data_err = file:write("Data: " .. value .. "\n")
if data_err then
    local _, close_err = file:close()
    if close_err then report_cleanup_error(close_err) end
    return nil, data_err
end
local _, sync_err = file:sync()
if sync_err then
    local _, close_err = file:close()
    if close_err then report_cleanup_error(close_err) end
    return nil, sync_err
end
local _, close_err = file:close()
if close_err then return nil, close_err end
```



## Checking Paths


```lua
local vol, get_err = fs.get("app:data")
if get_err then return nil, get_err end

-- Check existence
local exists, exists_err = vol:exists("/cache/results.json")
if exists_err then return nil, exists_err end
if exists then
    return vol:readfile("/cache/results.json")
end

-- Check if directory
local is_dir, isdir_err = vol:isdir(path)
if isdir_err then return nil, isdir_err end
if is_dir then
    process_directory(path)
end

-- Get file info
local info, stat_err = vol:stat("/documents/report.pdf")
if stat_err then return nil, stat_err end
print(info.size, info.modified, info.type)
```

**Stat fields:** `name`, `size`, `mode`, `modified`, `is_dir`, `type`



## Directory Operations


```lua
local vol, get_err = fs.get("app:data")
if get_err then return nil, get_err end

-- Create directory
local _, mkdir_err = vol:mkdir("/uploads/" .. user_id)
if mkdir_err then return nil, mkdir_err end

-- List directory contents
local iter, state = vol:readdir("/documents")
if not iter then return nil, state end
for entry in iter, state do
    print(entry.name, entry.type)
end

-- Remove file or empty directory
local removed, remove_err = vol:remove("/temp/file.txt")
if remove_err then return nil, remove_err end
return removed
```

Entry fields: `name`, `type` ("file" or "directory")

`mkdir` creates one directory and does not create missing parents. `remove` accepts files and empty directories only.



## File Handle Methods


When using `vol:open()` for streaming:

| Method | Description |
|--------|-------------|
| `read(size?)` | Read bytes (default: 4096) |
| `write(data)` | Write string data |
| `seek(whence, offset)` | Set position ("set", "cur", "end") |
| `stat()` | Get file info (same fields as `vol:stat`) |
| `sync()` | Flush to storage |
| `close()` | Release file handle |
| `scanner(split?)` | Create line/word scanner |

Call `close()` after finishing with a file handle.



## Scanner


Use a scanner for line-by-line processing:

```lua
local file, err = vol:open("/data/users.csv", "r")
if err then
    return nil, err
end
local scanner, err = file:scanner("lines")
if err then
    local _, close_err = file:close()
    if close_err then report_cleanup_error(close_err) end
    return nil, err
end

scanner:scan()  -- skip header

while scanner:scan() do
    local line = scanner:text()
    process(line)
end

local scan_err = scanner:err()
if scan_err then
    local _, close_err = file:close()
    if close_err then report_cleanup_error(close_err) end
    return nil, scan_err
end

local _, close_err = file:close()
if close_err then return nil, close_err end
```

Split modes: `"lines"` (default), `"words"`, `"bytes"`, `"runes"`

`scanner:scan()` returns only a boolean. When it returns `false`, call `scanner:err()` to distinguish clean EOF from a tokenization or underlying read failure. `scanner:err()` returns a structured `INTERNAL` error or `nil`; unlike a stream scanner, a file scanner has no separate scan-dispatch error return.



## Constants


```lua
fs.type.FILE      -- "file"
fs.type.DIR       -- "directory"

fs.seek.SET       -- from start
fs.seek.CUR       -- from current
fs.seek.END       -- from end
```



## FS Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `readfile(path)` / `read_file(path)` | `string, error` | Read entire file |
| `writefile(path, data, mode?)` / `write_file(path, data, mode?)` | `boolean, error` | Write a string or reader-backed value |
| `exists(path)` | `boolean, error` | Check if path exists |
| `stat(path)` | `table, error` | Get file info |
| `isdir(path)` | `boolean, error` | Check if directory |
| `mkdir(path)` | `boolean, error` | Create directory |
| `remove(path)` | `boolean, error` | Remove file/empty dir |
| `readdir(path)` | `iterator, state` | List directory (use in generic `for` loop) |
| `open(path, mode)` | `File, error` | Open file handle |
| `chdir(path)` | `boolean, error` | Change working dir |
| `pwd()` | `string, error` | Get working dir |



## Permissions


Security policy evaluation applies when a volume is acquired.

| Action | Resource | Description |
|--------|----------|-------------|
| `fs.get` | Volume ID | Acquire filesystem volume |



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty path | `errors.INVALID` | unspecified |
| Path contains a null byte | `errors.INVALID` | no |
| Invalid mode | `errors.INVALID` | unspecified |
| `scanner()` called on a closed file | `errors.INVALID` | unspecified |
| Read, write, seek, stat, or sync called on a closed file | `errors.INTERNAL` | no |
| `close()` called on an already closed file | succeeds | not applicable |
| File-handle read reached EOF | `errors.NOT_FOUND` | unspecified |
| Path not found | `errors.NOT_FOUND` | preserved from the underlying error when available |
| Path already exists | `errors.ALREADY_EXISTS` | unspecified |
| Permission denied | `errors.PERMISSION_DENIED` | no |
| File scanner tokenization or read failed | `errors.INTERNAL` | preserved from the underlying error when available |

`unspecified` means `err:retryable()` returns `nil`; it is not equivalent to `false`.

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Key-Value Store" (lua/storage/store)
Next: "Cloud Storage" (lua/storage/cloud)
