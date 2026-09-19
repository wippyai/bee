# "Compression"

_Path: en/lua/data/compress_

> "Compress and decompress data using gzip, deflate, zlib, brotli, and zstd algorithms."

## Table of Contents

- Compression

## Content

# Compression

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="workflow"/>
<secondary-label ref="encoding"/>

The `compress` module encodes and decodes strings with gzip, Brotli, Zstandard, raw DEFLATE, and zlib.

This is an API reference with partial HTTP and storage recipes. Every operation materializes its complete input and output as Lua strings; use the archive or stream APIs when data must remain streaming. The examples assume the entry enables `compress` and any separately required modules such as `json` or `http`.



## Loading


```lua
local compress = require("compress")
```

Add `compress` to the executable entry's `modules:` list before requiring it.



## GZIP


Gzip is defined by RFC 1952.



### Compress {id="gzip-compress"}


```lua
-- Compress for HTTP response
local body, json_err = json.encode(large_response)
if json_err then return nil, json_err end
local compressed, err = compress.gzip.encode(body)
if err then
    return nil, err
end

-- Set Content-Encoding header
local header_err = res:set_header("Content-Encoding", "gzip")
if header_err then return nil, header_err end
local write_err = res:write(compressed)
if write_err then return nil, write_err end

-- Maximum compression for storage
local archived, archive_err = compress.gzip.encode(data, {level = 9})
if archive_err then return nil, archive_err end

-- Fast compression for real-time
local fast, fast_err = compress.gzip.encode(data, {level = 1})
if fast_err then return nil, fast_err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to compress |
| `options` | table? | Optional encoding options |



#### Options {id="gzip-compress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `level` | integer | Compression level 1-9 (default: 6) |

**Returns:** `string, error`



### Decompress {id="gzip-decompress"}


```lua
-- Decompress HTTP request
local content_encoding, header_err = req:header("Content-Encoding")
if header_err then return nil, header_err end
if content_encoding == "gzip" then
    local body, body_err = req:body()
    if body_err then return nil, body_err end
    local decompressed, err = compress.gzip.decode(body)
    if err then
        return nil, errors.new("Invalid gzip data"):kind(errors.INVALID)
    end
    body = decompressed
end

-- Decompress with size limit (prevent zip bombs)
local decompressed, err = compress.gzip.decode(data, {max_size = 10 * 1024 * 1024})
if err then
    return nil, errors.new("Decompressed size exceeds 10MB limit"):kind(errors.INVALID)
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | GZIP compressed data |
| `options` | table? | Optional decoding options |



#### Options {id="gzip-decompress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `max_size` | integer | Max decompressed size in bytes (default: 128MB, max: 1GB) |

**Returns:** `string, error`



## Brotli


Brotli is defined by RFC 7932 and is commonly used for compressed text content.



### Compress {id="brotli-compress"}


```lua
-- Best for static assets and text content
local compressed, err = compress.brotli.encode(html_content, {level = 11})
if err then return nil, err end

-- Store `compressed` through the application's cache contract if needed.

-- Moderate compression for API responses
local compressed, err = compress.brotli.encode(json_data, {level = 4})
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to compress |
| `options` | table? | Optional encoding options |



#### Options {id="brotli-compress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `level` | integer | Compression level 0-11 (default: 6) |

**Returns:** `string, error`



### Decompress {id="brotli-decompress"}


```lua
local decompressed, err = compress.brotli.decode(compressed_data)
if err then
    return nil, err
end

-- With size limit
local decompressed, err = compress.brotli.decode(data, {max_size = 50 * 1024 * 1024})
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Brotli compressed data |
| `options` | table? | Optional decoding options |



#### Options {id="brotli-decompress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `max_size` | integer | Max decompressed size in bytes (default: 128MB, max: 1GB) |

**Returns:** `string, error`



## Zstandard


Zstandard is a general-purpose compression format defined by RFC 8878.



### Compress {id="zstd-compress"}


```lua
-- Good balance of speed and ratio
local compressed, err = compress.zstd.encode(binary_data)
if err then return nil, err end

-- Higher compression for archival
local archived, archive_err = compress.zstd.encode(data, {level = 19})
if archive_err then return nil, archive_err end

-- Fast mode for latency-sensitive payloads
local fast, fast_err = compress.zstd.encode(data, {level = 1})
if fast_err then return nil, fast_err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to compress |
| `options` | table? | Optional encoding options |



#### Options {id="zstd-compress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `level` | integer | Compression level 1-22 (default: 3) |
| `dict` | string? | Zstd dictionary bytes from `train_dict` (default: none) |

**Returns:** `string, error`



### Decompress {id="zstd-decompress"}


```lua
local decompressed, err = compress.zstd.decode(compressed_data)
if err then
    return nil, err
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Zstandard compressed data |
| `options` | table? | Optional decoding options |



#### Options {id="zstd-decompress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `max_size` | integer | Max decompressed size in bytes (default: 128MB, max: 1GB) |
| `dict` | string? | Zstd dictionary bytes (must match the dict used to encode) |

**Returns:** `string, error`



### Dictionaries {id="zstd-dictionaries"}


Train a dictionary from similar sample payloads, then pass it through the `dict` option to `encode` and `decode`. Decoding requires the same dictionary used for encoding.

```lua
local dict, err = compress.zstd.train_dict(samples, { size = 112640 })
if err then return nil, err end
local packed, pack_err = compress.zstd.encode(data, { dict = dict })
if pack_err then return nil, pack_err end
local original, decode_err = compress.zstd.decode(packed, { dict = dict })
if decode_err then return nil, decode_err end
```



#### train_dict(samples, options?)


| Parameter | Type | Description |
|-----------|------|-------------|
| `samples` | string[] | Training samples (at least one >= 8 bytes) |
| `options` | table? | `size` (integer, target dict bytes, 256-1048576, default 114688), `id` (integer, default 0), `level` (integer, 1-22) |

**Returns:** `string, error` (the dictionary bytes)



#### inspect_dict(dict)


| Parameter | Type | Description |
|-----------|------|-------------|
| `dict` | string | Dictionary bytes |

**Returns:** `table, error` — `{id: integer, content_size: integer}`



## Deflate


Raw DEFLATE is defined by RFC 1951 and is also used inside other formats.



### Compress {id="deflate-compress"}


```lua
local compressed, err = compress.deflate.encode(data, {level = 6})
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to compress |
| `options` | table? | Optional encoding options |



#### Options {id="deflate-compress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `level` | integer | Compression level 1-9 (default: 6) |

**Returns:** `string, error`



### Decompress {id="deflate-decompress"}


```lua
local decompressed, err = compress.deflate.decode(compressed)
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | DEFLATE compressed data |
| `options` | table? | Optional decoding options |



#### Options {id="deflate-decompress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `max_size` | integer | Max decompressed size in bytes (default: 128MB, max: 1GB) |

**Returns:** `string, error`



## Zlib


Zlib wraps DEFLATE data with a header and checksum as defined by RFC 1950.



### Compress {id="zlib-compress"}


```lua
local compressed, err = compress.zlib.encode(data, {level = 6})
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Data to compress |
| `options` | table? | Optional encoding options |



#### Options {id="zlib-compress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `level` | integer | Compression level 1-9 (default: 6) |

**Returns:** `string, error`



### Decompress {id="zlib-decompress"}


```lua
local decompressed, err = compress.zlib.decode(compressed)
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | string | Zlib compressed data |
| `options` | table? | Optional decoding options |



#### Options {id="zlib-decompress-options"}


| Field | Type | Description |
|-------|------|-------------|
| `max_size` | integer | Max decompressed size in bytes (default: 128MB, max: 1GB) |

**Returns:** `string, error`



## Choosing an Algorithm


| Algorithm | Best For | Speed | Ratio | Level Range |
|-----------|----------|-------|-------|-------------|
| gzip | HTTP, wide compatibility | Medium | Good | 1-9 |
| brotli | Static assets, text | Slow | Best | 0-11 |
| zstd | Binary payloads, fast compression | Fast | Good | 1-22 |
| deflate/zlib | Low-level, specific protocols | Medium | Good | 1-9 |

```lua
-- HTTP response based on Accept-Encoding
local accept, header_err = req:header("Accept-Encoding")
if header_err then return nil, header_err end
accept = accept or ""
local body, json_err = json.encode(response_data)
if json_err then return nil, json_err end

local qualities = {}
for item in accept:gmatch("[^,]+") do
    local coding = item:match("^%s*([^;%s]+)")
    local has_q = item:match(";%s*[qQ]%s*=") ~= nil
    local q_text = item:match(";%s*[qQ]%s*=%s*([^;%s,]+)")
    local q
    if not has_q then
        q = 1
    elseif q_text == "0" or q_text == "1" or
           (q_text and q_text:match("^0%.%d?%d?%d?$")) or
           (q_text and q_text:match("^1%.0?0?0?$")) then
        q = tonumber(q_text)
    end
    if coding and q and q >= 0 and q <= 1 then
        coding = coding:lower()
        qualities[coding] = math.max(qualities[coding] or 0, q)
    end
end

local function quality(coding)
    if qualities[coding] ~= nil then return qualities[coding] end
    if coding == "identity" then
        return qualities["*"] == 0 and 0 or 1
    end
    return qualities["*"] or 0
end

local selected, selected_q = nil, -1
for _, coding in ipairs({"br", "gzip", "identity"}) do
    local q = quality(coding)
    if q > selected_q then
        selected, selected_q = coding, q
    end
end

-- Include every field used by this handler or its surrounding middleware.
local vary_fields = {"Accept-Encoding"}
local vary_err = res:set_header("Vary", table.concat(vary_fields, ", "))
if vary_err then return nil, vary_err end

if selected_q <= 0 then
    local status_err = res:set_status(http.STATUS.NOT_ACCEPTABLE)
    if status_err then return nil, status_err end
    local write_err = res:write("No acceptable content encoding")
    if write_err then return nil, write_err end
elseif selected == "br" then
    local compressed, compress_err = compress.brotli.encode(body)
    if compress_err then return nil, compress_err end
    local set_err = res:set_header("Content-Encoding", "br")
    if set_err then return nil, set_err end
    local write_err = res:write(compressed)
    if write_err then return nil, write_err end
elseif selected == "gzip" then
    local compressed, compress_err = compress.gzip.encode(body)
    if compress_err then return nil, compress_err end
    local set_err = res:set_header("Content-Encoding", "gzip")
    if set_err then return nil, set_err end
    local write_err = res:write(compressed)
    if write_err then return nil, write_err end
else
    local write_err = res:write(body)
    if write_err then return nil, write_err end
end
```

This partial handler parses exact coding tokens and RFC q-values, honors explicit rejections such as `br;q=0`, and emits `Vary: Accept-Encoding`. `set_header` replaces an existing `Vary` value, so add every other field used by surrounding middleware to `vary_fields` before setting it. A full HTTP stack may provide a shared negotiation helper instead.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty input | `errors.INVALID` | no |
| Level out of range | `errors.INVALID` | no |
| Invalid compressed data | `errors.INVALID` | no |
| Decompressed size exceeds limit | `errors.INTERNAL` (gzip, zlib, zstd) / `errors.INVALID` (deflate, brotli) | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Base64 Encoding" (lua/data/base64)
Next: "Archive" (lua/data/archive)
