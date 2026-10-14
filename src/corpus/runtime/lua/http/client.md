# "HTTP Client"

_Path: en/lua/http/client_

> "Make HTTP requests to external services. Supports all HTTP methods, headers, query parameters, form data, file uploads, streaming responses, and…"

## Table of Contents

- HTTP Client

## Content

# HTTP Client

<secondary-label ref="network"/>
<secondary-label ref="io"/>
<secondary-label ref="permissions"/>

The `http_client` module sends HTTP requests with headers, query parameters, forms, file uploads, authentication, TLS options, streaming responses, and concurrent batches.

This is an API reference with partial request recipes. URLs, tokens, credentials, request data, and certificate material come from the surrounding application. Examples check `Response, error` before consuming a response and close streamed bodies explicitly.



## Loading


```lua
local http_client = require("http_client")
```

Add `http_client` to the executable entry's `modules:` list before requiring it. JSON and filesystem recipes also require `json` and `fs`.



## HTTP Methods


Convenience methods use the `method(url, options?)` signature and return `Response, error`.



### GET


Send a `GET` request.

```lua
local resp, err = http_client.get("https://api.example.com/users")
if err then
    return nil, err
end

print(resp.status_code)  -- 200
print(resp.body)         -- response body
```



### POST


Send a `POST` request.

```lua
local json = require("json")

local body, body_err = json.encode({name = "Alice", email = "alice@example.com"})
if body_err then return nil, body_err end
local resp, err = http_client.post("https://api.example.com/users", {
    headers = {["Content-Type"] = "application/json"},
    body = body
})
if err then return nil, err end
```



### PUT


Send a `PUT` request.

```lua
local body, body_err = json.encode({name = "Alice Smith"})
if body_err then return nil, body_err end
local resp, err = http_client.put("https://api.example.com/users/123", {
    headers = {["Content-Type"] = "application/json"},
    body = body
})
if err then return nil, err end
```



### PATCH


Send a `PATCH` request.

```lua
local body, body_err = json.encode({status = "active"})
if body_err then return nil, body_err end
local resp, err = http_client.patch("https://api.example.com/users/123", {
    headers = {["Content-Type"] = "application/json"},
    body = body
})
if err then return nil, err end
```



### DELETE


Send a `DELETE` request.

```lua
local resp, err = http_client.delete("https://api.example.com/users/123", {
    headers = {["Authorization"] = "Bearer " .. token}
})
if err then return nil, err end
```



### HEAD


A `HEAD` request returns headers without a response body.

```lua
local resp, err = http_client.head("https://cdn.example.com/file.zip")
if err then return nil, err end
local size = resp.headers["Content-Length"]
```



### Custom Methods


Send a request using an explicit HTTP method string.

```lua
local resp, err = http_client.request("PROPFIND", "https://dav.example.com/folder", {
    headers = {["Depth"] = "1"}
})
if err then return nil, err end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `method` | string | HTTP method |
| `url` | string | Request URL |
| `options` | table | Request options (optional) |



## Request Options


| Field | Type | Description |
|-------|------|-------------|
| `headers` | table | Request headers `{["Name"] = "value"}` |
| `body` | string | Request body |
| `query` | table | Query parameters `{key = "value"}` |
| `form` | table | Form data (sets Content-Type automatically) |
| `files` | table | File uploads (array of file definitions) |
| `cookies` | table | Request cookies `{name = "value"}` |
| `auth` | table | Basic auth `{user = "name", pass = "secret"}` |
| `timeout` | number/string | Timeout: number in seconds, or string like `"30s"`, `"1m"` |
| `stream` | boolean | Stream response body instead of buffering |
| `max_response_body` | number | Max response size in bytes (0 = default) |
| `unix_socket` | string | Connect via Unix socket path |
| `tls` | table | Per-request TLS configuration (see [TLS Options](#tls-options)) |
| `overlay_network` | string | Route through a [network overlay](system/network.md) — registry ID of a `network.socks5` / `network.tailscale` / `network.i2p` entry |

Selecting `overlay_network` requires `network.select` permission on that network ID.



### Query Parameters


```lua
local resp, err = http_client.get("https://api.example.com/search", {
    query = {
        q = "lua programming",
        page = "1",
        limit = "20"
    }
})
if err then return nil, err end
```



### Headers and Authentication


```lua
local resp, err = http_client.get("https://api.example.com/data", {
    headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/json"
    }
})
if err then return nil, err end

-- Or use basic auth
local resp, err = http_client.get("https://api.example.com/data", {
    auth = {user = service_user, pass = service_password}
})
if err then return nil, err end
```

Load authentication values from application-owned secret storage and send them only over TLS.



### Form Data


```lua
local resp, err = http_client.post("https://api.example.com/login", {
    form = {
        username = username,
        password = password
    }
})
if err then return nil, err end
```



### File Upload


```lua
local resp, err = http_client.post("https://api.example.com/upload", {
    form = {title = "My Document"},
    files = {
        {
            name = "attachment",      -- form field name
            filename = "report.pdf",  -- original filename
            content = pdf_data,       -- file content
            content_type = "application/pdf"
        }
    }
})
if err then return nil, err end
```

| File Field | Type | Required | Description |
|------------|------|----------|-------------|
| `name` | string | yes | Form field name |
| `filename` | string | no | Original filename |
| `content` | string | yes* | File content |
| `reader` | userdata | yes* | Alternative: io.Reader for content |
| `content_type` | string | no | Currently ignored: each uploaded part is always sent with `Content-Type: application/octet-stream` regardless of this field |

\* Either `content` or `reader` is required.

The pinned runtime fully reads a `reader` into memory before dispatch, does not close it, and does not surface a non-EOF read failure separately; it can send the bytes accumulated before that failure. Prefer `content` for already-bounded data, and close caller-owned readers after the request. The `content_type` field is parsed but not forwarded by runtime `v0.3.32a`, so uploaded parts use the transport default.

Reader-backed files are supported only by single-request calls in this release. `request_batch` forwards the `content` field but drops a parsed `reader`, so batch file uploads must provide `content`.



### Timeout


```lua
-- Number: seconds
local resp, err = http_client.get(url, {timeout = 30})
if err then return nil, err end

-- String alternatives use Go duration format: "30s", "1m30s", or "1h".
```



### TLS Options


Configure mutual TLS and custom CA certificates for one request.

| Field | Type | Description |
|-------|------|-------------|
| `cert` | string | Client certificate in PEM format |
| `key` | string | Client private key in PEM format |
| `ca` | string | Custom CA certificate in PEM format |
| `server_name` | string | Server name for SNI verification |
| `insecure_skip_verify` | boolean | Skip TLS certificate verification |

For mutual TLS, provide `cert` and `key` together. The `ca` field replaces the system certificate pool with a custom CA.



#### mTLS Authentication


```lua
local fs = require("fs")
local certs, volume_err = fs.get("app:certs")
if volume_err then return nil, volume_err end
local cert_pem, cert_err = certs:readfile("client.crt")
if cert_err then return nil, cert_err end
local key_pem, key_err = certs:readfile("client.key")
if key_err then return nil, key_err end

local resp, err = http_client.get("https://secure.example.com/api", {
    tls = {
        cert = cert_pem,
        key = key_pem,
    }
})
if err then return nil, err end
```



#### Custom CA


```lua
local fs = require("fs")
local certs, volume_err = fs.get("app:certs")
if volume_err then return nil, volume_err end
local ca_pem, ca_err = certs:readfile("internal-ca.crt")
if ca_err then return nil, ca_err end

local resp, err = http_client.get("https://internal.example.com/api", {
    tls = {
        ca = ca_pem,
        server_name = "internal.example.com",
    }
})
if err then return nil, err end
```



#### Insecure Skip Verify


`insecure_skip_verify` disables TLS verification and requires the `http_client.insecure_tls` security permission.

```lua
local resp, err = http_client.get("https://localhost:8443/api", {
    tls = {
        insecure_skip_verify = true,
    }
})
if err then return nil, err end
```

Use `insecure_skip_verify` only for a controlled diagnostic endpoint. It disables both certificate-chain and hostname verification.



## Response Object


| Field | Type | Description |
|-------|------|-------------|
| `status_code` | number | HTTP status code |
| `body` | string | Response body (if not streaming) |
| `body_size` | number | Body size in bytes (-1 if streaming) |
| `headers` | table | Response headers |
| `cookies` | table | Response cookies |
| `url` | string | Final URL (after redirects) |
| `stream` | Stream | Stream object (if `stream = true`) |

```lua
local resp, err = http_client.get("https://api.example.com/data")
if err then
    return nil, err
end

if resp.status_code == 200 then
    local data, decode_err = json.decode(resp.body)
    if decode_err then return nil, decode_err end
    print("Content-Type:", resp.headers["Content-Type"])
end
```



## Streaming Responses


Set `stream = true` to process a response incrementally rather than buffering its full body.

```lua
local resp, err = http_client.get("https://cdn.example.com/large-file.zip", {
    stream = true
})
if err then
    return nil, err
end

-- Process in chunks
local read_err
while true do
    local chunk
    chunk, read_err = resp.stream:read(65536)
    if read_err or not chunk then break end
    -- process chunk
end
local _, close_err = resp.stream:close()
if read_err then return nil, read_err end
if close_err then return nil, close_err end
```

| Stream Method | Returns | Description |
|---------------|---------|-------------|
| `read(n?)` | string, error | Read up to `n` bytes (default: implementation buffer) |
| `close()` | boolean, error | Close the stream |

`resp.stream` is a full [stream](lua/core/stream.md) object — `seek`, `stat`, and `scanner` are also available. The caller owns a streamed response body and should close it on every exit; task cleanup is a fallback, not a substitute for prompt release.



## Batch Requests


`request_batch` executes multiple requests concurrently.

```lua
local requests = {
    {"GET", "https://api.example.com/users"},
    {"GET", "https://api.example.com/products"},
    {"POST", "https://api.example.com/log", {body = "event"}}
}
local responses, batch_errors = http_client.request_batch(requests)

if not responses then
    return nil, batch_errors  -- whole-batch dispatch or validation failure
end

if batch_errors then
    for i = 1, #requests do
        local err = batch_errors[i]
        if err then
            print("Request " .. i .. " failed:", err)
        end
    end
else
    -- All succeeded
    for i, resp in ipairs(responses) do
        print("Response " .. i .. ":", resp.status_code)
    end
end
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `requests` | table | Array of `{method, url, options?}` |

**Returns:** `responses, errors` — arrays indexed by request position

**Notes:**

- Requests execute concurrently
- Streaming (`stream = true`) is not supported in batch
- Reader-backed file uploads are not supported in batch; use `files[].content`
- Result arrays match request order (1-indexed)



### Encode


Encode a string for inclusion in a URL.

```lua
local encoded = http_client.encode_uri("hello world")
-- "hello+world"

local url = "https://api.example.com/search?q=" .. http_client.encode_uri(query)
```



### Decode


Decode a string previously encoded with `http_client.encode_uri`.

```lua
local decoded, err = http_client.decode_uri("hello+world")
if err then return nil, err end
-- "hello world"
```



## Permissions


HTTP requests are evaluated against the active security policy.



### Security Actions


| Action | Resource | Description |
|--------|----------|-------------|
| `http_client.request` | URL | Allow/deny requests to specific URLs |
| `http_client.unix_socket` | Socket path | Allow/deny Unix socket connections |
| `http_client.private_ip` | IP address | Allow/deny access to private IP ranges |
| `http_client.insecure_tls` | URL | Allow/deny insecure TLS (skip verification) |
| `network.select` | Network entry ID | Allow/deny routing through the `overlay_network` given in the request |



### Checking Access


```lua
local security = require("security")

if security.can("http_client.request", "https://api.example.com/users") then
    local resp, request_err = http_client.get("https://api.example.com/users")
    if request_err then return nil, request_err end
end
```



### SSRF Protection


Non-public IP ranges are blocked by default. Access requires the `http_client.private_ip` permission on the address:

- loopback, private (10.x, 172.16-31.x, 192.168.x), link-local unicast and multicast, and the unspecified address
- carrier-grade NAT `100.64.0.0/10`, `192.0.0.0/24`, multicast `224.0.0.0/4`, reserved `240.0.0.0/4`
- documentation and benchmarking ranges `192.0.2.0/24`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32`
- IPv6 multicast `ff00::/8`

```lua
local resp, err = http_client.get("http://192.168.1.1/admin")
-- Error: not allowed: private IP 192.168.1.1
```

The check runs at dial time, not on the URL string, and it covers every address the host resolves to. A hostname that resolves to several addresses is checked address by address: a denied address is skipped and the next one is tried, and the request fails only when every candidate is denied or unreachable. A public hostname that resolves to a private address is therefore blocked exactly like a private IP literal.



### Redirects


Up to nine redirects are followed; the tenth fails with `stopped after 10 redirects`, a count that includes the original request.

Every hop is authorized on its own. Before following a redirect the client evaluates `http_client.request` against the target URL and applies the private-IP check to it, so a permitted URL cannot be used to reach a denied one by redirection. A hop that fails either check aborts the request.

See [Security Model](system/security.md) for policy configuration.



## Errors


| Condition | Kind | Retryable |
|-----------|------|-----------|
| Security policy denied | `errors.PERMISSION_DENIED` | no |
| Private IP blocked | `errors.PERMISSION_DENIED` | no |
| Unix socket denied | `errors.PERMISSION_DENIED` | no |
| Insecure TLS denied | `errors.PERMISSION_DENIED` | no |
| Invalid batch item, batch streaming, or invalid URI escape | `errors.INVALID` | no |
| No context | `errors.INTERNAL` | no |
| Malformed transport URL or network failure | `errors.INTERNAL` | yes |
| Timeout | `errors.INTERNAL` | yes |

Many unsupported option values are ignored rather than returned as structured errors. Invalid Lua argument types and an empty batch raise Lua argument errors. Validate application-supplied option tables before calling the client.

```lua
local resp, err = http_client.get(url)
if err then
    if errors.is(err, errors.PERMISSION_DENIED) then
        print("Access denied:", err:message())
    elseif err:retryable() then
        print("Temporary error:", err:message())
    end
    return nil, err
end
```

See [Error Handling](lua/core/errors.md) for working with errors.



## Navigation

Previous: "HTTP" (lua/http/http)
Next: "WebSocket Client" (lua/http/websocket)
