# "Archive"

_Path: en/lua/data/archive_

> "Read and write zip/tar archives with bounded memory. Archives are never loaded into RAM nor extracted to disk — peak memory is independent of archive…"

## Table of Contents

- Archive

## Content

# Archive

<secondary-label ref="function"/>
<secondary-label ref="io"/>
<secondary-label ref="encoding"/>

Read and write zip/tar archives with bounded memory. Archives are never loaded into RAM nor extracted to disk — peak memory is independent of archive and entry size, so multi-GB archives run on a low-RAM server.



## Loading


```lua
local archive = require("archive")
```



## Formats


Built-in formats are detected by magic bytes, or forced with `opts.format`:

| Format | Random read | Sequential scan | Write |
|--------|:-----------:|:---------------:|:-----:|
| `zip` | yes | yes (local headers) | yes |
| `tar` | yes | yes | yes |
| `tar.gz` | no | yes | yes |
| `tar.zst` | no | yes | yes |

`archive.formats()` returns the list of registered format names.

```lua
local names = archive.formats()  -- {"zip", "tar", "tar.gz", "tar.zst", ...}
```



## Options


All entrypoints accept an optional `opts` table:

| Key | Default | Meaning |
|-----|---------|---------|
| `format` | auto | `"zip"`, `"tar"`, `"tar.gz"`, `"tar.zst"`; auto = sniff magic, else extension |
| `max_entries` | 100000 | Reject archives with more entries (decompression-bomb defense) |
| `max_total_bytes` | 2 GiB | Cap on cumulative uncompressed output during read/extract |
| `max_file_bytes` | 1 GiB | Cap on a single entry's uncompressed size |
| `max_inline_bytes` | 16 MiB | Hard cap for the RAM-materializing `read()` call; above it, use `stream()`/`extract()` |
| `buffer_bytes` | 64 KiB | Streaming copy buffer for read/extract/add |

`max_total_bytes`/`max_file_bytes` are work caps, not RAM caps — streaming an entry never holds more than `buffer_bytes` plus the codec's decompression window. The only RAM-sizing knob is `max_inline_bytes`.



## Reading — Random Access


`archive.open(source, ...)` opens a **seekable** source for full random access (zip central directory is read up front; entries decompress on demand). The source may be an `fs.FS` handle plus a path, an open `fs.File`, raw bytes (bytes hold the whole archive in RAM — small archives only), or any random-access reader handed over by another module.

A reader from another module qualifies when it implements `io.ReaderAt` and reports its `Size`; an optional `Name` is used for extension sniffing when `opts.format` is omitted. [`cloudstorage`](lua/storage/cloud.md) `open_reader` is one, which reads a multi-GB archive directly out of object storage. The archive opens nothing in that case and never closes the reader — its owner does.

```lua
local fs = require("fs")
local archive = require("archive")

-- Open by fs handle + path (the module opens the file and owns its lifecycle)
local r, err = archive.open(fs.get("app:uploads"), "incoming.zip")
-- Or from an already-open seekable fs.File
-- local r = archive.open(fs:get("app:uploads"):open("x.zip"))
-- Or from raw bytes (small archives only)
-- local r = archive.open(zip_bytes, { format = "zip" })
-- Or from a random-access reader owned by another module
-- local reader = cloudstorage.get("app:files"):open_reader("incoming.zip")
-- local r = archive.open(reader)
```

**Returns:** `Reader, error`

**Permission:** `archive.read`



### entries


Iterate the directory (metadata only — no decompression):

```lua
for e in r:entries() do
    -- e: name, size, compressed_size, is_dir, mode, modified, method, crc32, type
    print(e.name, e.size, e.is_dir)
end
```



### stat


Get entry metadata by name (no decompression):

```lua
local info, err = r:stat("docs/readme.md")
```



### read


Materialize a single entry as a Lua string. Errors (`kind = Invalid`) above `max_inline_bytes` — for anything large, use `stream()` or `extract()`:

```lua
local data, err = r:read("docs/readme.md")  -- small entries only
```



### stream


Return the entry as a `stream.Stream` that decompresses on demand. Composes everywhere a stream does — `:scanner()`, `fs:writefile()`, or handed to another module:

```lua
local es, err = r:stream("big.csv")
while true do
    local chunk = es:read(65536)
    if not chunk then break end
    process(chunk)
end
es:close()
```



### extract


Stream one entry into a destination filesystem:

```lua
local ok, err = r:extract("docs/readme.md", fs.get("app:out"))
-- optional destination path:
-- r:extract("docs/readme.md", fs.get("app:out"), "readme.md")
```



### extract_all


Stream every entry into a destination filesystem:

```lua
local count, err = r:extract_all(fs.get("app:out"), {
    prefix = "job123/",          -- prepend to each destination path
    strip  = 1,                  -- drop N leading path components
    filter = function(e) return not e.is_dir end,
})
```

Entry names are sanitized on extract — `..` segments, absolute paths, and Windows drive/UNC prefixes are rejected (zip-slip defense).



### close


Close the reader. Idempotent; also auto-closed at task scope.

```lua
r:close()
```



## Reading — Sequential Scan


`archive.scan(source, opts?)` opens a **forward-only** stream (an HTTP upload body, a multipart file stream). Entries are visited in archive order; each entry's reader is valid only until you advance. No random `read(name)`.

```lua
local up = form.files.upload[1]:stream()        -- stream.Stream
local s, err = archive.scan(up, { format = "zip" })

for e, entry in s:walk() do                      -- entry is a stream.Stream
    if not e.is_dir then
        fs.get("app:uploads"):writefile("job123/" .. e.name, entry)
    end
end
s:close()
```

**Returns:** `Walker, error`

**Permission:** `archive.read`

A walker also supports `extract_all` with the same options as the random-access reader, streaming every entry into a destination filesystem in one call:

```lua
local count, err = s:extract_all(fs.get("app:uploads"), { prefix = "job123/" })
```

`tar`, `tar.gz`, and `tar.zst` stream natively. `zip` is parsed via per-entry local headers; entries written with a streaming data descriptor (size/CRC trailing the data) are read by decompressing to the entry boundary. For robust zip handling of large uploads, land the upload as a file first (a bounded sequential copy) then use `archive.open`:

```lua
local dst = fs.get("app:tmp")
dst:writefile("u.zip", req:stream())   -- streaming copy upload → fs file
local r = archive.open(dst, "u.zip")   -- robust random access
-- ... entries / extract_all ...
r:close()
dst:remove("u.zip")
```



## Writing


`archive.create(dest, ...)` builds an archive by streaming entries into a destination — a file in an fs (with a path) or a writable `stream.Stream` (e.g. an HTTP response), so a download `.zip` is generated straight to the wire with bounded memory.

```lua
local w, err = archive.create(fs.get("app:tmp"), "out.zip", { format = "zip" })
-- or stream to a response:
-- local w = archive.create(res:stream(), { format = "zip" })
```

**Returns:** `Writer, error`

**Permission:** `archive.write`



### add


Add an entry from a string, bytes, reader, or `stream.Stream`:

```lua
w:add("notes.txt", "hello")
w:add("from_upload", some_stream, { method = "deflate", mode = tonumber("644", 8) })
```



### add_file


Stream an entry from a file in a filesystem:

```lua
w:add_file("data/big.bin", fs.get("app:data"), "big.bin")
```



### add_dir


Add a directory entry:

```lua
w:add_dir("empty/")
```



### close


Finalize the archive (writes the central directory for zip). Idempotent; also auto-closed at task scope.

```lua
w:close()
```

`add*` options: `{ method = "store"|"deflate", mode, size }`. Tar formats need the entry size up front, so `add()` from a stream or reader into a `tar*` archive requires `size` (strings and `add_file` supply it). The zip writer streams to non-seekable writers using data descriptors, so writing to a response stream works.



## Errors


| Condition | Kind |
|-----------|------|
| Source is not an fs handle, an fs file, bytes or a random-access reader | `errors.INVALID` |
| Unknown / mismatched format | `errors.INVALID` |
| Corrupt or truncated archive | `errors.INVALID` |
| Limit exceeded (entries / total / file / inline) | `errors.INVALID` |
| Random access on a stream-only format (use `scan`) | `errors.UNAVAILABLE` |
| Entry name not found | `errors.NOT_FOUND` |
| Source not readable / destination not writable | `errors.PERMISSION_DENIED` |
| Read a stale streamed entry after the walk advanced | `errors.INTERNAL` |

See [Error Handling](lua/core/errors.md) for working with errors.



## See Also


- [Filesystem](lua/storage/filesystem.md) - Source and destination filesystems
- [Stream](lua/core/stream.md) - Stream objects handed to and from archives
- [Compression](lua/data/compress.md) - In-memory gzip/deflate/zstd
- [Cloud Storage](lua/storage/cloud.md) - `open_reader` as a random-access archive source



## Navigation

Previous: "Compression" (lua/data/compress)
Next: "Payload Encoding" (lua/data/payload)
