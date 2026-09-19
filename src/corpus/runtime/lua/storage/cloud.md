# "Cloud Storage"

_Path: en/lua/storage/cloud_

> "Access S3-compatible object storage. Upload, download, list, and manage objects, presign download, upload and multipart-part URLs, and read objects…"

## Table of Contents

- Cloud Storage

## Content

# Cloud Storage

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>
<secondary-label ref="external"/>
<secondary-label ref="permissions"/>

Access S3-compatible object storage. Upload, download, list, and manage objects, presign download, upload and multipart-part URLs, and read objects with random access.

For storage configuration, see [Cloud Storage](system/cloudstorage.md).



## Loading


```lua
local cloudstorage = require("cloudstorage")
```



## Acquiring Storage


Acquire a cloud storage resource by registry ID:

```lua
local storage, err = cloudstorage.get("app.infra:files")
if err then
    return nil, err
end

local uploaded, upload_err = storage:upload_object("data/file.txt", "content")
storage:release()
if upload_err then return nil, upload_err end
return uploaded
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | string | Storage resource ID |

**Returns:** `Storage, error`



## Uploading Objects


Upload content from a string or file:

```lua
local json = require("json")

local storage, storage_err = cloudstorage.get("app.infra:files")
if storage_err then return nil, storage_err end

-- Upload string content
local body, encode_err = json.encode({
    date = "2024-01-15",
    total = 1234
})
if encode_err then
    storage:release()
    return nil, encode_err
end
local ok, err = storage:upload_object("reports/daily.json", body)
if err then
    storage:release()
    return nil, err
end

-- Upload from file
local fs = require("fs")
local vol, fs_err = fs.get("app:data")
if fs_err then
    storage:release()
    return nil, fs_err
end
local file, open_err = vol:open("/large-file.bin", "r")
if open_err then
    storage:release()
    return nil, open_err
end

local uploaded, file_upload_err = storage:upload_object("backups/large-file.bin", file)
local _, close_err = file:close()

storage:release()
if file_upload_err then
    if close_err then report_cleanup_error(close_err) end
    return nil, file_upload_err
end
if close_err then return nil, close_err end
return uploaded
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key/path |
| `content` | string or Reader | Content as string or file reader |
| `options` | table | Optional metadata and conditional write options |

**Returns:** `boolean, error`



### Upload Options


Attach metadata or guard the write with an options table:

```lua
local uploaded, err = storage:upload_object("reports/daily.json", body, {
    content_type = "application/json",
    cache_control = "max-age=3600",
    metadata = { owner = "team-a", run_id = "1234" },  -- stored as x-amz-meta-*
    only_if_absent = true                              -- fail if the key already exists
})
if err then return nil, err end
return uploaded
```

| Option | Type | Description |
|--------|------|-------------|
| `content_type` | string | MIME type |
| `cache_control` | string | Cache-Control header |
| `content_disposition` | string | Content-Disposition header |
| `content_encoding` | string | Content-Encoding header |
| `metadata` | table | User metadata (string keys/values), stored as `x-amz-meta-*` |
| `headers` | table | Additional request headers (string keys/values) |
| `if_match` | string | Write only if the current object ETag matches |
| `if_none_match` | string | Write only if no object matches the ETag (`"*"` means any) |
| `only_if_absent` | boolean | Write only if the key does not exist (alias for `if_none_match = "*"`) |

A conditional write that fails its precondition returns a `precondition_failed` error.



## Downloading Objects


Download an object to a file writer:

```lua
local fs = require("fs")
local storage, storage_err = cloudstorage.get("app.infra:files")
if storage_err then return nil, storage_err end
local vol, fs_err = fs.get("app:temp")
if fs_err then
    storage:release()
    return nil, fs_err
end

local file, open_err = vol:open("/downloaded.json", "w")
if open_err then
    storage:release()
    return nil, open_err
end
local ok, err = storage:download_object("reports/daily.json", file)
local _, close_err = file:close()
if err then
    if close_err then report_cleanup_error(close_err) end
    storage:release()
    return nil, err
end
if close_err then
    storage:release()
    return nil, close_err
end

-- Download partial content (first 1KB)
local partial, partial_open_err = vol:open("/partial.bin", "w")
if partial_open_err then
    storage:release()
    return nil, partial_open_err
end
local partial_ok, partial_err = storage:download_object("backups/large-file.bin", partial, {
    range = "bytes=0-1023"
})
local _, partial_close_err = partial:close()

storage:release()
if partial_err then
    if partial_close_err then report_cleanup_error(partial_close_err) end
    return nil, partial_err
end
if partial_close_err then return nil, partial_close_err end
return partial_ok
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key to download |
| `writer` | Writer | Destination file writer |
| `options.range` | string | Byte range (e.g., "bytes=0-1023") |
| `options.if_match` | string | Download only if the object ETag matches |
| `options.if_none_match` | string | Download only if the ETag does not match |

**Returns:** `boolean, error`

A failed precondition (`if_match`/`if_none_match`) returns a `precondition_failed` error.



## Listing Objects


List objects with optional prefix filtering:

```lua
local storage, storage_err = cloudstorage.get("app.infra:files")
if storage_err then return nil, storage_err end

local result, err = storage:list_objects({
    prefix = "reports/2024/",
    max_keys = 100
})
if err then
    storage:release()
    return nil, err
end

for _, obj in ipairs(result.objects) do
    print(obj.key, obj.size, obj.etag)
end

-- Paginate through large results
local token = nil
repeat
    local page, page_err = storage:list_objects({
        prefix = "logs/",
        max_keys = 1000,
        continuation_token = token
    })
    if page_err then
        storage:release()
        return nil, page_err
    end
    for _, obj in ipairs(page.objects) do
        process(obj)
    end
    token = page.next_continuation_token
    if not page.is_truncated then break end
until false

storage:release()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `options.prefix` | string | Filter by key prefix |
| `options.max_keys` | integer | Maximum objects to return |
| `options.continuation_token` | string | Pagination token |
| `options.include_owner` | boolean | Include each object's `owner` (`id`, `display_name`) |
| `options.include_versions` | boolean | List object versions; each item includes `version_id` |

**Returns:** `table, error`

Result contains `objects`, `is_truncated`, `next_continuation_token`. Each object has `key`, `size`, `etag`, `storage_class`, and optional `last_modified`, `version_id`, and `owner`.

<note>
In list results <code>content_type</code> is always empty — S3 list operations do not return it. Use <code>head_object</code> to read an object's content type and metadata.
</note>



## Object Metadata


Fetch a single object's metadata without downloading its body:

```lua
local storage, storage_err = cloudstorage.get("app.infra:files")
if storage_err then return nil, storage_err end

local meta, err = storage:head_object("reports/daily.json")
if err then
    storage:release()
    return nil, err
end

print(meta.size, meta.etag, meta.content_type)
for k, v in pairs(meta.metadata) do
    print("meta", k, v)
end

storage:release()
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key |

**Returns:** `table, error`

Result fields:

| Field | Type | Description |
|-------|------|-------------|
| `size` | integer | Object size in bytes |
| `etag` | string | Entity tag |
| `content_type` | string | MIME type |
| `cache_control` | string | Cache-Control header |
| `content_disposition` | string | Content-Disposition header |
| `content_encoding` | string | Content-Encoding header |
| `storage_class` | string | Storage class |
| `version_id` | string | Version ID (present when versioning is enabled) |
| `last_modified` | integer | Last modified time (Unix seconds) |
| `metadata` | table | User metadata (`x-amz-meta-*`) |
| `headers` | table | Raw response headers (lowercased keys) |

A missing object returns a `not_found` error.



## Deleting Objects


Remove multiple objects:

```lua
local storage, storage_err = cloudstorage.get("app.infra:files")
if storage_err then return nil, storage_err end

local deleted, err = storage:delete_objects({
    "temp/file1.txt",
    "temp/file2.txt",
    "temp/file3.txt"
})

storage:release()
if err then return nil, err end
return deleted
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `keys` | string[] | Array of object keys to delete |

**Returns:** `boolean, error`

Every key is attempted. Deleting a key that does not exist is not an error. When the provider reports per-key failures, the call returns a single error naming each failed key and its provider error code.



## Download URLs


Create a temporary URL that permits downloading an object without storage credentials. A client can use the URL until it expires.

```lua
local storage, err = cloudstorage.get("app.infra:files")
if err then
    return nil, err
end

local url, err = storage:presigned_get_url("reports/quarterly.pdf", {
    expiration = 3600
})

storage:release()

if err then
    return nil, err
end

-- Return URL to client for direct download
return {download_url = url}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key |
| `options.expiration` | integer | Seconds until URL expires (default: 3600) |

**Returns:** `string, error`



## Upload URLs


Create a temporary URL that permits uploading an object without storage credentials. A client can upload directly to storage until the URL expires.

```lua
local storage, err = cloudstorage.get("app.infra:files")
if err then
    return nil, err
end

local url, err = storage:presigned_put_url("uploads/user-123/avatar.jpg", {
    expiration = 600,
    content_type = "image/jpeg",
    content_length = 1024 * 1024
})

storage:release()

if err then
    return nil, err
end

-- Return URL to client for direct upload
return {upload_url = url}
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key |
| `options.expiration` | integer | Seconds until URL expires (default: 3600) |
| `options.content_type` | string | Required content type for upload |
| `options.content_length` | integer | Expected upload size in bytes |

**Returns:** `string, error`



## Multipart Uploads


A single presigned PUT caps an object at 5 GiB. A presigned multipart upload splits a larger object into parts that a client uploads directly, then assembles them server-side. Multipart is a provider capability: S3 implements it, and providers without it return `errors.UNAVAILABLE`.

```lua
local storage = cloudstorage.get("app.infra:files")

local mp, err = storage:create_multipart_upload("backups/huge.zip", {
    content_type = "application/zip",
    metadata = { source = "uploader" },
})
if err then return nil, err end

local urls, err = storage:presigned_part_urls("backups/huge.zip", mp.upload_id, {
    count = 3,
    expiration = 900,
})
if err then
    storage:abort_multipart_upload("backups/huge.zip", mp.upload_id)
    return nil, err
end

-- The client PUTs each url and returns the ETag from the response headers.
local done, err = storage:complete_multipart_upload("backups/huge.zip", mp.upload_id, {
    { part_number = 1, etag = etag1 },
    { part_number = 2, etag = etag2 },
    { part_number = 3, etag = etag3 },
})

storage:release()
```



### create_multipart_upload


Start a multipart upload for a key.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key of the final object |
| `options` | table | `content_type`, `cache_control`, `content_disposition`, `content_encoding`, `metadata`, `headers` - same semantics as `upload_object` |

**Returns:** `table, error` - the table carries `upload_id`, which identifies the upload for every later part, complete and abort call.

Conditional writes (`if_match`, `if_none_match`, `only_if_absent`) are not part of the multipart protocol and are not accepted here.



### presigned_part_urls


Generate presigned PUT URLs for parts of an in-progress upload. Each URL is uploaded to with a plain HTTP PUT; the uploader must keep the `ETag` response header of each part for `complete_multipart_upload`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `key` | string | required | Object key |
| `upload_id` | string | required | From `create_multipart_upload` |
| `options.parts` | int[] | - | Explicit part numbers (1-10000, no duplicates) |
| `options.count` | int | - | Presign parts `1..count` |
| `options.headers` | table | - | Headers required on each part request; they are signed and must also be sent by the uploader |
| `options.expiration` | int | 3600 | Seconds until the URLs expire |

Exactly one of `parts` or `count` is required, and a single call presigns at most 1000 URLs - presign in pages for very large objects.

**Returns:** `table, error` - an array of `{ part_number, url }`.

Every part except the last must be at least 5 MiB; the provider enforces this at completion time.



### complete_multipart_upload


Assemble the final object from its uploaded parts. Parts may be reported in any order and are sorted by part number before completion.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key |
| `upload_id` | string | From `create_multipart_upload` |
| `parts` | table | Array of `{ part_number = int, etag = string }` |

**Returns:** `table, error` - `etag`, plus `version_id` and `location` when the provider reports them. An unknown upload ID returns `errors.NOT_FOUND`.



### abort_multipart_upload


Discard an in-progress upload and free its stored parts.

| Parameter | Type | Description |
|-----------|------|-------------|
| `key` | string | Object key |
| `upload_id` | string | From `create_multipart_upload` |

**Returns:** `boolean, error`

An upload that is never completed keeps its parts stored, and billed, until it is aborted. Abort on every failure path, and configure a bucket lifecycle rule as a backstop - see [Cloud Storage](system/cloudstorage.md#multipart-uploads).



## Ranged Readers


`open_reader` opens random access over an object using ranged GETs - no local staging and no full download. Its main consumer is [`archive.open`](lua/data/archive.md), which reads multi-GB archives straight out of object storage with bounded memory.

```lua
local archive = require("archive")
local storage = cloudstorage.get("app.infra:files")

local reader, err = storage:open_reader("uploads/huge.zip", {
    block_size = 8 * 1024 * 1024,
    cache_blocks = 4,
})
if err then return nil, err end

local r = assert(archive.open(reader))
for e in r:entries() do
    print(e.name, e.size)
end
r:close()
reader:close()

storage:release()
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `key` | string | required | Object key |
| `options.block_size` | int | 8388608 | Ranged-GET unit in bytes (64 KiB to 128 MiB) |
| `options.cache_blocks` | int | 4 | Resident LRU blocks (1 to 64) |

`block_size * cache_blocks` may not exceed 256 MiB. A missing object returns `errors.NOT_FOUND`.

**Returns:** `Reader, error`

The object's ETag is pinned when the reader opens and sent as `If-Match` on every ranged read, so an object overwritten mid-read fails the read with the provider's precondition error instead of serving a mix of two object generations; `archive` surfaces it as `errors.INTERNAL`. A provider that cannot supply an ETag returns `errors.UNAVAILABLE`; the reader never serves an unpinned object.

Cache-miss reads perform blocking network IO in the calling task and serialize concurrent readers, so sequential per-entry access - the archive pattern - is the intended shape.



### Reader Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `size()` | `integer` | Object size in bytes, from the open-time stat |
| `key()` | `string` | Object key the reader reads from |
| `close()` | `boolean, error` | Release the block cache; idempotent |

The reader is closed automatically at task scope if it is not closed explicitly.



## Storage Methods


| Method | Returns | Description |
|--------|---------|-------------|
| `upload_object(key, content, opts?)` | `boolean, error` | Upload string or file content |
| `download_object(key, writer, opts?)` | `boolean, error` | Download to file writer |
| `head_object(key)` | `table, error` | Fetch object metadata |
| `list_objects(opts?)` | `table, error` | List objects with prefix filter |
| `delete_objects(keys)` | `boolean, error` | Delete multiple objects |
| `presigned_get_url(key, opts?)` | `string, error` | Generate temporary download URL |
| `presigned_put_url(key, opts?)` | `string, error` | Generate temporary upload URL |
| `create_multipart_upload(key, opts?)` | `table, error` | Start a presigned multipart upload |
| `presigned_part_urls(key, upload_id, opts)` | `table, error` | Presign PUT URLs for upload parts |
| `complete_multipart_upload(key, upload_id, parts)` | `table, error` | Assemble the object from uploaded parts |
| `abort_multipart_upload(key, upload_id)` | `boolean, error` | Discard an in-progress multipart upload |
| `open_reader(key, opts?)` | `Reader, error` | Open a ranged random-access reader |
| `release()` | `boolean` | Release storage resource |



## Permissions


Security policy evaluation applies to cloud storage operations.

| Action | Resource | Description |
|--------|----------|-------------|
| `cloudstorage.get` | Storage ID | Acquire a storage resource |



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Empty resource ID | `errors.INVALID` | no |
| Resource not found | `errors.NOT_FOUND` | no |
| Not a cloud storage resource | `errors.INVALID` | no |
| Storage released | `errors.INVALID` | no |
| Empty key | `errors.INVALID` | no |
| Content nil | `errors.INVALID` | no |
| Writer not valid | `errors.INVALID` | no |
| Object not found | `errors.NOT_FOUND` | no |
| Unknown upload ID | `errors.NOT_FOUND` | no |
| Conditional precondition failed | `errors.CONFLICT` | no |
| Object overwritten during a ranged read (surfaced by `archive`) | `errors.INTERNAL` | no |
| Provider does not support multipart uploads | `errors.UNAVAILABLE` | no |
| Provider supplies no ETag for `open_reader` | `errors.UNAVAILABLE` | no |
| Permission denied | raised as a Lua error, not returned | - |
| Provider operation failed | `errors.UNKNOWN` | unset |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Filesystem" (lua/storage/filesystem)
Next: "Message Queue" (lua/storage/queue)
