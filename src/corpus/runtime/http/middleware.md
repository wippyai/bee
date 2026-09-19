# "HTTP Middleware"

_Path: en/http/middleware_

> "Middleware processes HTTP requests before and after route handling."

## Table of Contents

- HTTP Middleware

## Content

# HTTP Middleware


HTTP middleware runs in one of two router chains: before endpoint metadata is attached, or after the route has supplied its parameters and endpoint ID.

**Classification: middleware reference.** Each YAML block is a router fragment;
it assumes the named middleware is registered and any referenced token store,
filesystem, endpoint, actor, and policy entries exist.



## How Middleware Works


Each middleware receives an options map and returns a handler wrapper:

```yaml
middleware:
  - cors
  - ratelimit
options:
  cors.allow.origins: "https://example.com"
  ratelimit.requests: "100"
```

Options use dot notation: `middleware_name.option.name`. Legacy underscore format is supported for backward compatibility.



## Pre-Handler and Post-Match


<tip>
<b>Pre-handler</b> middleware runs after the server selects a route but before route metadata is attached—for concerns such as CORS and compression.
<b>Post-match</b> middleware runs after route metadata is attached—for authorization that needs the endpoint ID.
Neither chain runs for an unmatched request.
</tip>

```yaml
middleware:        # Before endpoint metadata
  - cors
  - compress
options:
  cors.allow.origins: "*"

post_middleware:   # Post-match
  - endpoint_firewall
post_options:
  endpoint_firewall.action: "access"
```

---



### CORS {#cors}


<note>Pre-handler</note>

Cross-Origin Resource Sharing for browser requests.

```yaml
middleware:
  - cors
options:
  cors.allow.origins: "https://app.example.com"
  cors.allow.credentials: "true"
```

| Option | Default | Description |
|--------|---------|-------------|
| `cors.allow.origins` | `*` | Allowed origins (comma-separated, supports `*.example.com`) |
| `cors.allow.methods` | `GET,POST,PUT,DELETE,OPTIONS,PATCH` | Allowed methods |
| `cors.allow.headers` | `Origin,Content-Type,Accept,Authorization,X-Requested-With` | Allowed request headers |
| `cors.expose.headers` | - | Headers exposed to client |
| `cors.allow.credentials` | `false` | Allow cookies/auth |
| `cors.max.age` | `86400` | Preflight cache (seconds) |
| `cors.allow.private.network` | `false` | Private network access |

OPTIONS preflight requests are handled automatically.

---



### Rate Limiting {#ratelimit}


<note>Pre-handler</note>

Token bucket rate limiting with per-key tracking.

```yaml
middleware:
  - ratelimit
options:
  ratelimit.requests: "100"
  ratelimit.window: "1m"
  ratelimit.key: "ip"
```

| Option | Default | Description |
|--------|---------|-------------|
| `ratelimit.requests` | `100` | Requests per window |
| `ratelimit.window` | `1m` | Time window |
| `ratelimit.burst` | `20` | Burst capacity |
| `ratelimit.key` | `ip` | Key strategy |
| `ratelimit.cleanup_interval` | `5m` | Cleanup frequency |
| `ratelimit.entry_ttl` | `10m` | Entry expiration |
| `ratelimit.max_entries` | `100000` | Max tracked keys |

**Key strategies:** `ip`, `header:X-API-Key`, `query:api_key`

Returns `429 Too Many Requests` with headers: `X-RateLimit-Limit`, `X-RateLimit-Window`.

---



### Compression {#compress}


<note>Pre-handler</note>

Gzip compression for responses.

```yaml
middleware:
  - compress
options:
  compress.level: "default"
  compress.min.length: "1024"
```

| Option | Default | Description |
|--------|---------|-------------|
| `compress.level` | `default` | `fastest`, `default`, or `best` |
| `compress.min.length` | `1024` | Minimum response size (bytes) |

Only compresses when client sends `Accept-Encoding: gzip`.

---



### Real IP {#real_ip}


<note>Pre-handler</note>

Extract client IP from proxy headers.

```yaml
middleware:
  - real_ip
options:
  real_ip.trusted.subnets: "10.0.0.0/8,172.16.0.0/12"
```

| Option | Default | Description |
|--------|---------|-------------|
| `real_ip.trusted.subnets` | Loopback, RFC 1918, link-local, CGNAT and IPv6 local ranges | Trusted proxy CIDRs |
| `real_ip.trust_all` | `false` | Trust all sources (insecure) |

**Header priority:** `True-Client-IP` > `X-Real-IP` > `X-Forwarded-For`

---



### Token Auth {#token_auth}


<note>Pre-handler</note>

Token-based authentication. See [Security](system/security.md) for token store configuration.

```yaml
middleware:
  - token_auth
options:
  token_auth.store: "app:tokens"
```

| Option | Default | Description |
|--------|---------|-------------|
| `token_auth.store` | required | Token store registry ID |
| `token_auth.header.name` | `Authorization` | Header name |
| `token_auth.header.prefix` | `Bearer ` | Header prefix |
| `token_auth.query.param` | `x-auth-token` | Query parameter fallback |
| `token_auth.cookie.name` | `x-auth-token` | Cookie fallback |

Sets actor and security scope in context for downstream middleware. Does not block requests—authorization happens in firewall middleware.

---



### Metrics {#metrics}


<note>Pre-handler</note>

Prometheus-style HTTP metrics. This middleware is registered only when a metrics collector is available, and it has no configuration options.

```yaml
middleware:
  - metrics
```

| Metric | Type | Description |
|--------|------|-------------|
| `wippy_http_requests_total` | Counter | Total requests |
| `wippy_http_request_duration_seconds` | Histogram | Request latency |
| `wippy_http_requests_in_flight` | Gauge | Concurrent requests |

---



### Endpoint Firewall {#endpoint_firewall}


<warning>Post-match</warning>

Authorization based on the matched endpoint. It requires an actor and security scope in the request context; `token_auth` is one way to supply them.

```yaml
post_middleware:
  - endpoint_firewall
post_options:
  endpoint_firewall.action: "access"
```

| Option | Default | Description |
|--------|---------|-------------|
| `endpoint_firewall.action` | `access` | Permission action to check |

Returns `401 Unauthorized` (no actor) or `403 Forbidden` (permission denied).

---



### Resource Firewall {#resource_firewall}


<warning>Post-match</warning>

Protect specific resources by ID. Useful at router level.

```yaml
post_middleware:
  - resource_firewall
post_options:
  resource_firewall.action: "admin"
  resource_firewall.target: "app:admin-panel"
```

| Option | Default | Description |
|--------|---------|-------------|
| `resource_firewall.action` | `access` | Permission action |
| `resource_firewall.target` | required | Resource registry ID |

---



### Sendfile {#sendfile}


<note>Pre-handler</note>

Serve files via `X-Sendfile` header from handlers.

```yaml
middleware:
  - sendfile
options:
  sendfile.fs: "app:downloads"
```

Handler sets headers to trigger file serving:

| Header | Description |
|--------|-------------|
| `X-Sendfile` | File path within filesystem |
| `X-File-Name` | Download filename |

Supports range requests for resumable downloads.

---



### WebSocket Relay {#websocket_relay}


<warning>Post-match</warning>

Relay WebSocket connections to processes. See [WebSocket Relay](http/websocket-relay.md).

```yaml
post_middleware:
  - websocket_relay
post_options:
  wsrelay.allowed.origins: "https://app.example.com"
```

---



### SSE Relay {#sse_relay}


<warning>Post-match</warning>

Stream Server-Sent Events from processes. See [Server-Sent Events](http/sse.md).

```yaml
post_middleware:
  - sse_relay
post_options:
  sserelay.allowed.origins: "https://app.example.com"
```

---



### OpenTelemetry {#otel}


<note>Pre-handler</note>

Records OpenTelemetry server spans for incoming requests. Always registered; acts as a no-op when OTel or its HTTP instrumentation is disabled.

```yaml
middleware:
  - otel
```

Takes no options. Works alongside the `metrics` middleware; enable both when you need Prometheus counters and OTel traces.

---



## Middleware Order


For requests, middleware executes in listed order; response handling unwinds in reverse order. Recommended sequence:

```yaml
middleware:
  - real_ip       # 1. Extract real IP first
  - cors          # 2. Handle CORS preflight
  - compress      # 3. Set up response compression
  - ratelimit     # 4. Check rate limits
  - metrics       # 5. Record metrics
  - token_auth    # 6. Authenticate requests

post_middleware:
  - endpoint_firewall  # Authorize after route match
```



## See Also


- [Routing](http/router.md) - Router configuration
- [Security](system/security.md) - Token stores and policies
- [WebSocket Relay](http/websocket-relay.md) - WebSocket handling
- [Server-Sent Events](http/sse.md) - SSE streaming
- [Terminal](system/terminal.md) - Terminal service



## Navigation

Previous: "HTTP Endpoints" (http/endpoint)
Next: "Static Files" (http/static)
