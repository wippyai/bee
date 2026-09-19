# "HTTP Server"

_Path: en/http/server_

> "The HTTP server (http.service) listens on a port and hosts routers, endpoints, and static file handlers."

## Table of Contents

- HTTP Server

## Content

# HTTP Server


An `http.service` owns a listener and hosts routers, endpoints, and static file handlers.

**Classification: server configuration reference.** Blocks are partial registry
fragments unless they define every referenced network, environment, filesystem,
router, certificate, actor, and policy entry.



## Configuration


```yaml
- name: gateway
  kind: http.service
  addr: ":8080"
  timeouts:
    read: "5s"
    write: "30s"
    idle: "60s"
  host:
    buffer_size: 1024
    worker_count: 4
  lifecycle:
    auto_start: true
    security:
      actor:
        id: "http-gateway"
      policies:
        - app:http_policy
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `addr` | string | required | Listen address (`:8080`, `0.0.0.0:443`) |
| `timeouts.read` | duration | - | Request read timeout |
| `timeouts.write` | duration | - | Response write timeout |
| `timeouts.idle` | duration | - | Keep-alive connection timeout |
| `host.buffer_size` | int | 1024 | Message relay buffer size |
| `host.worker_count` | int | NumCPU | Message relay workers |
| `network` | Registry ID | - | Bind listener through a [network overlay](system/network.md) (e.g. Tailscale, I2P) |
| `tls` | object | - | TLS termination (see [TLS](#tls)) |



## Timeouts


Configure timeouts to prevent resource exhaustion:

```yaml
timeouts:
  read: "10s"    # Max time to read the entire request (headers + body)
  write: "60s"   # Max time to write response
  idle: "120s"   # Keep-alive timeout
```

- `read` — Short (5–10 seconds) for APIs, longer for uploads
- `write` — Match the expected response generation time
- `idle` — Balance connection reuse against resource usage

<note>
Duration format: <code>30s</code>, <code>1m</code>, <code>2h15m</code>. Use <code>0</code> to disable.
</note>



## Host Configuration


The `host` section configures the server's internal message relay used by components like WebSocket relay:

```yaml
host:
  buffer_size: 2048
  worker_count: 8
```

| Field | Default | Description |
|-------|---------|-------------|
| `buffer_size` | 1024 | Message queue capacity per worker |
| `worker_count` | NumCPU | Parallel message processing goroutines |

<tip>
Increase these values for high-throughput WebSocket applications. The message relay handles async delivery between HTTP components and processes.
</tip>



## Security


HTTP servers can have a default security context applied through the lifecycle configuration:

```yaml
lifecycle:
  auto_start: true
  security:
    actor:
      id: "gateway-service"
    policies:
      - app:http_access_policy
```

This sets a baseline actor and policies for all requests. For authenticated requests, the [token_auth middleware](http/middleware.md) overrides the actor based on the validated token, allowing per-user security policies.



## Lifecycle


Servers are managed by the supervisor:

```yaml
lifecycle:
  auto_start: true
  start_timeout: 30s
  stop_timeout: 60s
  requires:
    - app:database
```

| Field | Description |
|-------|-------------|
| `auto_start` | Start when application starts |
| `start_timeout` | Max time to wait for server to start |
| `stop_timeout` | Max time for graceful shutdown |
| `requires` | Start after these entries are ready (`depends_on` is the legacy spelling) |



## Connecting Components


Routers and static handlers reference the server via metadata:

```yaml
entries:
  - name: gateway
    kind: http.service
    addr: ":8080"

  - name: api
    kind: http.router
    meta:
      server: gateway
    prefix: /api

  - name: static
    kind: http.static
    meta:
      server: gateway
    path: /
    fs: app:public
```



## Multiple Servers


Run separate servers for different purposes:

```yaml
entries:
  # Public API
  - name: public
    kind: http.service
    addr: ":8080"
    lifecycle:
      auto_start: true

  # Admin (localhost only)
  - name: admin
    kind: http.service
    addr: "127.0.0.1:9090"
    lifecycle:
      auto_start: true
```



## TLS


The server can terminate TLS directly. Set `tls.mode` to `manual` (supply your own certificate) or `auto` (certificate provided by an overlay network driver, e.g. `network.tailscale`). Plain clearnet listeners do not support `auto`. Omit `tls` or leave the mode empty to run plain HTTP.

In `auto` mode the server must not specify `cert`/`key` — the network driver provides them.



### Manual certificate


Under `mode: manual`, `cert` and `key` carry PEM content. Supply that content in one of three ways (pick one per field, never mix):

1. **Inline PEM** — the literal PEM string.
2. **`file://` reference** — manifest-relative path, resolved and inlined at load time (traversal-safe).
3. **Environment registry reference** — pull the PEM from a registered [env variable](system/env.md) at decode time, using a `${env:NAME}` placeholder.

```yaml
- name: api
  kind: http.service
  addr: ":443"
  tls:
    mode: manual
    cert: file://./certs/server.pem
    key:  file://./certs/server.key
```

```yaml
- name: api
  kind: http.service
  addr: ":443"
  tls:
    mode: manual
    cert: ${env:app.env:tls_cert}
    key:  ${env:app.env:tls_key}
```

The `${env:NAME}` placeholder resolves `NAME` through the [environment registry](system/env.md) — a registered variable's public name or its entry ID (e.g. `app.env:tls_cert`). It is not a raw OS environment variable; an OS value is only reachable when an `env.storage.os`-backed variable is registered under that name. A default can be supplied with `${env:NAME|default}`.

<note>
The legacy <code>cert_env</code> / <code>key_env</code> companion fields still resolve through the environment registry the same way, but are <b>deprecated</b> — prefer the <code>${env:NAME}</code> placeholder shown above.
</note>

| Field | Description |
|-------|-------------|
| `mode` | `""` (off), `auto`, or `manual` |
| `cert` / `key` | PEM content — inline, `file://` reference, or `${env:NAME}` placeholder |



### Mutual TLS (mTLS)


Under `mode: manual` the server can additionally verify client certificates:

```yaml
tls:
  mode: manual
  cert: ${env:app.env:tls_cert}
  key:  ${env:app.env:tls_key}
  client_ca: file://./certs/clients-ca.pem
  client_auth: require_and_verify
```

`client_ca` accepts the same three forms as `cert`/`key` (inline PEM, `file://`, or `${env:NAME}`). The legacy `client_ca_env` companion field is likewise deprecated in favor of `client_ca: ${env:NAME}`.

| Field | Description |
|-------|-------------|
| `client_auth` | `request`, `require_any`, `verify_if_given`, `require_and_verify` |
| `client_ca` | PEM bundle of trusted client CAs (inline, `file://`, or `${env:NAME}`) |

`verify_if_given` and `require_and_verify` require a CA. `request` and `require_any` accept any client cert without CA verification.



## See Also


- [Routing](http/router.md) - Routers and endpoints
- [Static Files](http/static.md) - Static file serving
- [Middleware](http/middleware.md) - Available middleware
- [Security](system/security.md) - Security policies
- [WebSocket Relay](http/websocket-relay.md) - WebSocket messaging



## Navigation

Previous: "Executor" (system/exec)
Next: "Routing" (http/router)
