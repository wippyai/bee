# "HTTP"

_Path: en/lua/http/http_

> "Handle HTTP requests and build responses. Access request data, route parameters, headers, and body content. Build responses with status codes…"

## Table of Contents

- HTTP

## Content

# HTTP

<secondary-label ref="function"/>
<secondary-label ref="process"/>
<secondary-label ref="io"/>

The `http` module reads the current server-side request and builds its response, including headers, route data, body content, streaming output, and Server-Sent Events.

This is an API reference with partial handler recipes. Names such as `id`, `data`, `token`, and application callbacks come from the surrounding handler. Request accessors generally return `value, error`, and response mutations return `error`; examples that consume a result check those errors.

For server configuration, see [HTTP Server](http/server.md).



## Loading


```lua
local http = require("http")
```

Add `http` to the executable entry's `modules:` list before requiring it. Examples using `uuid`, `fs`, or `time` require those modules separately.



## Accessing the Request


Read the current HTTP request context:

```lua
local req, err = http.request({
    timeout = 5000,        -- 5 second body read timeout
    max_body = 10485760    -- 10MB max body
})
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `options.timeout` | integer | Body read timeout in ms (default: 300000 / 5 min) |
| `options.max_body` | integer | Max body size in bytes (default: 120MB) |

**Returns:** `Request, error`



## Accessing the Response


Read the current HTTP response context:

```lua
local res, err = http.response()
if err then return nil, err end
```

**Returns:** `Response, error`



### `method`


Return the request's HTTP method.

```lua
local method, method_err = req:method()
if method_err then return nil, method_err end

if method == http.METHOD.GET then
    return get_resource(id)
elseif method == http.METHOD.POST then
    local data, body_err = req:body_json()
    if body_err then return nil, body_err end
    return create_resource(data)
elseif method == http.METHOD.PUT then
    local data, body_err = req:body_json()
    if body_err then return nil, body_err end
    return update_resource(id, data)
elseif method == http.METHOD.DELETE then
    return delete_resource(id)
end
```



### `path`


Return the request path.

```lua
local path, err = req:path()
if err then return nil, err end
print(path)  -- "/api/users/123"

-- Route based on path
if path:match("^/api/") then
    return handle_api(req)
end
```



### `query`


Return one query parameter:

```lua
-- GET /search?q=hello&page=2&limit=10
local query, query_err = req:query("q")
if query_err then return nil, query_err end

-- With defaults
local page_text, page_err = req:query("page")
if page_err then return nil, page_err end
local page = tonumber(page_text) or 1
```



### `query_params`


Return all query parameters. Multiple values for one key are joined with commas.

```lua
-- GET /search?tags=lua&tags=go&active=true
local params, err = req:query_params()
if err then return nil, err end
-- {tags = "lua,go", active = "true"}

for key, value in pairs(params) do
    print(key .. ": " .. value)
end
```



### `header`


Return one request header by name.

```lua
local uuid = require("uuid")

local auth, auth_err = req:header("Authorization")
if auth_err then return nil, auth_err end
if not auth then
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.UNAUTHORIZED)
    if status_err then return nil, status_err end
    return res:write_json({error = "Missing authorization"})
end

local correlation_id, correlation_err = req:header("X-Correlation-ID")
if correlation_err then return nil, correlation_err end
if not correlation_id then
    correlation_id, correlation_err = uuid.v4()
    if correlation_err then return nil, correlation_err end
end
```

Lookup is case-insensitive: `req:header("content-type")` and `req:header("Content-Type")` return the same value. A header sent more than once returns its values joined with `", "`. A header that is not present returns `nil`.



### headers


Gets every request header.

```lua
local headers, err = req:headers()
for name, value in pairs(headers) do
    print(name .. ": " .. value)
end
```

**Returns:** `table, error`

Keys are canonical header names (`Content-Type`, `X-Correlation-ID`), regardless of the casing the client sent. Repeated headers are joined with `", "`, as in `req:header()`.



### content_type


Return the `Content-Type` header:

```lua
local ct, type_err = req:content_type()  -- "application/json; charset=utf-8" or nil
if type_err then return nil, type_err end
```



### `content_length`


Return the `Content-Length` header value:

```lua
local length, length_err = req:content_length()  -- number of bytes
if length_err then return nil, length_err end
```



### `host`


Return the `Host` header:

```lua
local host, host_err = req:host()  -- "example.com:8080"
if host_err then return nil, host_err end
```



### `param`


Return one route parameter from a path pattern such as `/users/:id`:

```lua
-- Route: /users/:id/posts/:post_id
local id, param_err = req:param("id")
if param_err then return nil, param_err end
local valid = false
if id then
    local validate_err
    valid, validate_err = uuid.validate(id)
    if validate_err then return nil, validate_err end
end
if not valid then
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.BAD_REQUEST)
    if status_err then return nil, status_err end
    return res:write_json({error = "Invalid ID format"})
end
```



### `params`


Return all route parameters:

```lua
-- Route: /orgs/:org/repos/:repo/issues/:issue
local p, err = req:params()
if err then return nil, err end
-- {org = "acme", repo = "widget", issue = "123"}

local issue = get_issue(p.org, p.repo, p.issue)
```



### `body`


Read the full request body as a string:

```lua
local body, err = req:body()
if err then return nil, err end

-- Parse XML manually
local is_xml, type_err = req:is_content_type("application/xml")
if type_err then return nil, type_err end
if is_xml then
    local data = parse_xml(body)
end

-- Avoid logging raw request bodies; record only non-sensitive metadata.
logger.debug("Request body read", {length = #body})
```

`body()`, `body_json()`, `stream()`, and `parse_multipart()` consume the same request body. Choose one body-reading path per handler. `body()` and `body_json()` enforce the request object's timeout and size limit; `stream()` is incremental and does not apply those two options.



### `body_json`


Read and parse the request body as JSON:

```lua
local data, err = req:body_json()
if err then
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.BAD_REQUEST)
    if status_err then return nil, status_err end
    return res:write_json({error = "Invalid JSON: " .. err:message()})
end

-- Validate required fields
if not data.name or not data.email then
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.BAD_REQUEST)
    if status_err then return nil, status_err end
    return res:write_json({error = "Missing required fields"})
end

local user = create_user(data)
```



### `has_body`


Check whether the request has a body.

```lua
local has_body, body_state_err = req:has_body()
if body_state_err then return nil, body_state_err end
if has_body then
    local data, body_err = req:body_json()
    if body_err then return nil, body_err end
    process(data)
else
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.BAD_REQUEST)
    if status_err then return nil, status_err end
    return res:write_json({error = "Request body required"})
end
```

`has_body()` returns `true` only when the request has a body object and a positive `Content-Length`. A chunked request or another request with unknown length can return `false`; handlers that permit such bodies should attempt their chosen body reader and handle its error instead.



### `is_content_type`


Check whether the request has the specified content type.

```lua
local is_json, type_check_err = req:is_content_type("application/json")
if type_check_err then return nil, type_check_err end
if not is_json then
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(415)
    if status_err then return nil, status_err end
    return res:write_json({error = "Content-Type must be application/json"})
end
```



### `accepts`


Check whether the request accepts the specified content type.

```lua
local accepts_json, json_accept_err = req:accepts("application/json")
if json_accept_err then return nil, json_accept_err end
local accepts_html, html_accept_err = req:accepts("text/html")
if html_accept_err then return nil, html_accept_err end

if accepts_json then
    return res:write_json(data)
elseif accepts_html then
    local type_err = res:set_content_type("text/html; charset=utf-8")
    if type_err then return nil, type_err end
    return res:write(render_html(data))
else
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.NOT_ACCEPTABLE)
    if status_err then return nil, status_err end
    return res:write_json({error = "Cannot produce acceptable response"})
end
```

The pinned `accepts()` helper performs exact comma-separated matches plus `*/*`; it does not process media-type parameters, subtype wildcards, or quality weights, and a missing `Accept` header returns `false`. Use application-owned negotiation when those HTTP semantics matter.



### `remote_addr`


Return the client's remote network address.

```lua
local addr, addr_err = req:remote_addr()  -- "192.168.1.100:54321"
if addr_err then return nil, addr_err end

-- Extract the host from IPv4 and bracketed IPv6 addresses
local ip = addr:match("^%[([^%]]+)%]:%d+$")
    or addr:match("^([^:]+):%d+$")
    or addr

-- Rate limiting by IP
if rate_limiter:is_limited(ip) then
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.TOO_MANY_REQUESTS)
    if status_err then return nil, status_err end
    return res:write_json({error = "Too many requests"})
end
```



### `parse_multipart`


Parse multipart form data, including file uploads. The optional `max_memory` argument sets the number of bytes held in memory before data spills to temporary files; the default is 32 MB.

```lua
local uuid = require("uuid")

local form, err = req:parse_multipart()  -- or req:parse_multipart(8 * 1024 * 1024)
if err then
    local type_err = res:set_content_type(http.CONTENT.JSON)
    if type_err then return nil, type_err end
    local status_err = res:set_status(http.STATUS.BAD_REQUEST)
    if status_err then return nil, status_err end
    return res:write_json({error = "Invalid form data"})
end

-- Access form values
local title = form.values.title
local description = form.values.description

-- Access uploaded files
if form.files.avatar then
    local file = form.files.avatar[1]
    local filename, name_err = file:name()        -- untrusted client metadata
    if name_err then return nil, name_err end
    local size, size_err = file:size()
    if size_err then return nil, size_err end
    local content_type, header_err = file:header("Content-Type")  -- "image/jpeg"
    if header_err then return nil, header_err end

    -- Read file content
    local stream = file:stream()
    local parts = {}
    while true do
        local chunk, err = stream:read(65536)
        if err or not chunk then break end
        parts[#parts + 1] = chunk
    end
    stream:close()
    local content = table.concat(parts)

    local stream, stream_err = file:stream()
    if stream_err then return nil, stream_err end
    local stored_name, id_err = uuid.v7()
    if id_err then
        stream:close()
        return nil, id_err
    end
    local _, write_err = uploads:writefile(stored_name, stream, "wx")
    local _, close_err = stream:close()
    if write_err then return nil, write_err end
    if close_err then return nil, close_err end
end

-- Handle multiple files
if form.files.documents then
    for _, file in ipairs(form.files.documents) do
        process_document(file)
    end
end
```

Multipart field values are strings when a field occurs once and arrays when it occurs repeatedly. Treat uploaded filenames and `Content-Type` values as untrusted metadata; generate the storage name and inspect the content independently when its type matters.

The exclusive `wx` write prevents overwriting an existing object. A failed write does not prove that the target belongs to this request, so the failure path must not remove it blindly. Applications that need cleanup after partial writes should stage uploads under an ownership-tracked temporary name and promote them only after the write succeeds.



### `stream`


Read the request body as a stream:

```lua
local stream, stream_err = req:stream()
if stream_err then return nil, stream_err end

-- Process in chunks
local read_err
while true do
    local chunk
    chunk, read_err = stream:read(65536)  -- 64KB chunks
    if read_err or not chunk then break end
    process_chunk(chunk)
end
local _, close_err = stream:close()
if read_err then return nil, read_err end
if close_err then return nil, close_err end
```



### `set_status`


Set the response status code.

`set_status()` writes the status and commits the response headers immediately. Call `set_header()`, `set_content_type()`, or `set_transfer()` first; later header changes return `errors.INVALID`.

```lua
local status_err = res:set_status(http.STATUS.CREATED)
if status_err then return nil, status_err end

-- Other common choices: 204 No Content, 400 Bad Request,
-- 401 Unauthorized, 403 Forbidden, 404 Not Found, and 500 Internal Error.
```



### `set_header`


Set one response header.

```lua
local request_id_err = res:set_header("X-Request-ID", correlation_id)
if request_id_err then return nil, request_id_err end
local cache_err = res:set_header("Cache-Control", "max-age=3600")
if cache_err then return nil, cache_err end
local rate_err = res:set_header("X-RateLimit-Remaining", tostring(remaining))
if rate_err then return nil, rate_err end

-- CORS headers
local origin_err = res:set_header("Access-Control-Allow-Origin", "*")
if origin_err then return nil, origin_err end
local methods_err = res:set_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE")
if methods_err then return nil, methods_err end
local headers_err = res:set_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
if headers_err then return nil, headers_err end
```



### `set_content_type`


Set the response content type.

```lua
local type_err = res:set_content_type(http.CONTENT.JSON)
if type_err then return nil, type_err end

-- Other examples: "text/html; charset=utf-8" or "application/pdf".
```



### `write`


Write to the response body:

```lua
local write_err = res:write("Hello, World!")
if write_err then return nil, write_err end

-- Build response incrementally
for _, fragment in ipairs({
    "<html><body>",
    "<h1>Title</h1>",
    "<p>Content</p>",
    "</body></html>"
}) do
    local fragment_err = res:write(fragment)
    if fragment_err then return nil, fragment_err end
end
```



### `write_json`


Encode a value as JSON and write it to the response:

```lua
-- Success response
local write_err = res:write_json({
    data = users,
    total = count,
    page = page
})
if write_err then return nil, write_err end

-- Error response
local type_err = res:set_content_type(http.CONTENT.JSON)
if type_err then return nil, type_err end
local status_err = res:set_status(http.STATUS.BAD_REQUEST)
if status_err then return nil, status_err end
local error_write_err = res:write_json({
    error = "Validation failed",
    details = {
        {field = "email", message = "Invalid format"},
        {field = "age", message = "Must be positive"}
    }
})
if error_write_err then return nil, error_write_err end
```

`write()`, `write_json()`, `flush()`, and `write_event()` also commit headers. `write_json()` sets `Content-Type: application/json` only when headers have not already been committed.



### `flush`


Flush buffered response data to the client:

<code-block lang="lua">
-- Stream progress updates
for i = 1, 100 do
    local write_err = res:write(string.format("Progress: %d%%\n", i))
    if write_err then return nil, write_err end
    local flush_err = res:flush()
    if flush_err then return nil, flush_err end
    local _, sleep_err = time.sleep("100ms")
    if sleep_err then return nil, sleep_err end
end
</code-block>



### `set_transfer`


Set the transfer mode for a streaming response:

```lua
-- Chunked transfer
local transfer_err = res:set_transfer(http.TRANSFER.CHUNKED)
if transfer_err then return nil, transfer_err end
for chunk in get_chunks() do
    local write_err = res:write(chunk)
    if write_err then return nil, write_err end
    local flush_err = res:flush()
    if flush_err then return nil, flush_err end
end

-- Server-Sent Events
local sse_err = res:set_transfer(http.TRANSFER.SSE)
if sse_err then return nil, sse_err end
```



### `write_event`


Write a Server-Sent Event:

```lua
-- Real-time updates
local transfer_err = res:set_transfer(http.TRANSFER.SSE)
if transfer_err then return nil, transfer_err end

local connected_err = res:write_event({name = "connected", data = {client_id = client_id}})
if connected_err then return nil, connected_err end

for progress in task:progress() do
    local event_err = res:write_event({name = "progress", data = {percent = progress}})
    if event_err then return nil, event_err end
end

local complete_err = res:write_event({name = "complete", data = {result = result}})
if complete_err then return nil, complete_err end

-- Chat messages
local message_err = res:write_event({name = "message", data = {
    from = "alice",
    text = "Hello!",
    timestamp = time.now():unix()
}})
if message_err then return nil, message_err end
```



### HTTP Methods


```lua
http.METHOD.GET
http.METHOD.POST
http.METHOD.PUT
http.METHOD.DELETE
http.METHOD.PATCH
http.METHOD.HEAD
http.METHOD.OPTIONS
```



### Status Codes


```lua
-- Success (2xx)
http.STATUS.OK                   -- 200
http.STATUS.CREATED              -- 201
http.STATUS.ACCEPTED             -- 202
http.STATUS.NO_CONTENT           -- 204
http.STATUS.PARTIAL_CONTENT      -- 206

-- Redirect (3xx)
http.STATUS.MOVED_PERMANENTLY    -- 301
http.STATUS.FOUND                -- 302
http.STATUS.SEE_OTHER            -- 303
http.STATUS.NOT_MODIFIED         -- 304
http.STATUS.TEMPORARY_REDIRECT   -- 307
http.STATUS.PERMANENT_REDIRECT   -- 308

-- Client Error (4xx)
http.STATUS.BAD_REQUEST          -- 400
http.STATUS.UNAUTHORIZED         -- 401
http.STATUS.PAYMENT_REQUIRED     -- 402
http.STATUS.FORBIDDEN            -- 403
http.STATUS.NOT_FOUND            -- 404
http.STATUS.METHOD_NOT_ALLOWED   -- 405
http.STATUS.NOT_ACCEPTABLE       -- 406
http.STATUS.CONFLICT             -- 409
http.STATUS.GONE                 -- 410
http.STATUS.UNPROCESSABLE        -- 422
http.STATUS.TOO_MANY_REQUESTS    -- 429

-- Server Error (5xx)
http.STATUS.INTERNAL_ERROR       -- 500 (alias: INTERNAL_SERVER_ERROR)
http.STATUS.NOT_IMPLEMENTED      -- 501
http.STATUS.BAD_GATEWAY          -- 502
http.STATUS.SERVICE_UNAVAILABLE  -- 503
http.STATUS.GATEWAY_TIMEOUT      -- 504
http.STATUS.VERSION_NOT_SUPPORTED -- 505
```



### Content Types


```lua
http.CONTENT.JSON       -- "application/json"
http.CONTENT.FORM       -- "application/x-www-form-urlencoded"
http.CONTENT.MULTIPART  -- "multipart/form-data"
http.CONTENT.TEXT       -- "text/plain"
http.CONTENT.STREAM     -- "application/octet-stream"
```



### Transfer Modes


```lua
http.TRANSFER.CHUNKED   -- "chunked"
http.TRANSFER.SSE       -- "sse"
```



### Legacy Error-Type Constants


The module exports these compatibility strings, but current request and response methods do not return them. Runtime failures use the structured `errors.*` kinds described below.

```lua
http.ERROR.PARSE_FAILED   -- Form/multipart parse error
http.ERROR.INVALID_STATE  -- Invalid response state
http.ERROR.WRITE_FAILED   -- Response write error
http.ERROR.STREAM_ERROR   -- Body stream error
```



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| No HTTP context | `errors.INTERNAL` | no |
| Body too large | `errors.INVALID` | no |
| Read timeout | `errors.INTERNAL` | no |
| Invalid JSON | `errors.INVALID` | no |
| Not multipart | `errors.INVALID` | no |
| Headers already sent | `errors.INVALID` | no |
| Write failed | `errors.INTERNAL` | no |

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "Excel Spreadsheets" (lua/data/excel)
Next: "HTTP Client" (lua/http/client)
