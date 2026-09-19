# "Routing"

_Path: en/http/router_

> "Routers group endpoints under URL prefixes and apply shared middleware. Endpoints define HTTP handlers."

## Table of Contents

- Routing

## Content

# Routing


An `http.router` groups endpoints under a URL prefix and applies shared middleware. Each `http.endpoint` defines an HTTP handler.

**Classification: routing reference.** Configuration blocks are partial registry
fragments unless they include a namespace and every referenced entry. Handler
blocks use application-owned function IDs rather than defining a data layer.



## Architecture


```mermaid
flowchart TB
    S[http.service<br/>:8080] --> R1[http.router<br/>/api]
    S --> R2[http.router<br/>/admin]
    S --> ST[http.static<br/>/]

    R1 --> E1[GET /users]
    R1 --> E2[POST /users]
    R1 --> E3["GET /users/{id}"]

    R2 --> E4[GET /stats]
    R2 --> E5[POST /config]
```

Entries reference parents via metadata:

- Routers: `meta.server: app:gateway`
- Endpoints: `meta.router: app:api`



## Router Configuration


```yaml
- name: api
  kind: http.router
  meta:
    server: gateway
  prefix: /api/v1
  middleware:
    - cors
    - compress
  options:
    cors.allow.origins: "*"
  post_middleware:
    - endpoint_firewall
```

| Field | Type | Description |
|-------|------|-------------|
| `meta.server` | Registry ID | Parent HTTP server |
| `prefix` | string | URL prefix for all routes |
| `middleware` | []string | Pre-match middleware |
| `options` | map | Middleware options |
| `post_middleware` | []string | Post-match middleware |
| `post_options` | map | Post-match middleware options |



## Endpoint Configuration


```yaml
- name: get_user
  kind: http.endpoint
  meta:
    router: api
  method: GET
  path: /users/{id}
  func: app.users:get_user
```

| Field | Type | Description |
|-------|------|-------------|
| `meta.router` | Registry ID | Parent router |
| `method` | string | HTTP method: `GET`, `POST`, `PUT`, `DELETE`, `PATCH`, `HEAD`, `OPTIONS`, `TRACE`, or `*` for any method |
| `path` | string | URL path pattern (starts with `/`) |
| `func` | Registry ID | Handler function |



## Path Parameters


Use `{param}` syntax for URL parameters:

```yaml
- name: get_post
  kind: http.endpoint
  meta:
    router: api
  method: GET
  path: /users/{user_id}/posts/{post_id}
  func: get_user_post
```

Access in handler:

```lua
local http = require("http")

local function handler()
    local req, req_err = http.request()
    if req_err then return nil, req_err end
    local user_id, user_err = req:param("user_id")
    if user_err then return nil, user_err end
    local post_id, post_err = req:param("post_id")
    if post_err then return nil, post_err end

    return {user_id = user_id, post_id = post_id}
end
```



### Wildcard Paths


Capture remaining path segments with `{param...}`:

```yaml
- name: serve_files
  kind: http.endpoint
  meta:
    router: api
  method: GET
  path: /files/{filepath...}
  func: serve_file
```

The wildcard matches the remaining segments, so a request like `GET /api/v1/files/docs/guides/readme.md` is dispatched to the handler. The captured tail is read with `req:param` under the name without the trailing dots:

```lua
local filepath = req:param("filepath")  -- "docs/guides/readme.md"
```

The wildcard must be the last segment in the path.



## Route Precedence


All routers register their endpoints into a single pattern set, prefixed by the router's `prefix`, and Go's `ServeMux` decides which pattern serves a request. Its rules apply unchanged:

- The most specific pattern wins. A pattern is more specific than another when it matches a strict subset of that pattern's requests, so `/users/admin` beats `/users/{id}`, and `/files/{name}` beats `/files/{path...}`.
- A pattern with a method is more specific than the same path without one, so a `GET` endpoint takes precedence over a `*` endpoint on the same path for `GET` requests.
- A trailing `{path...}` or `/` matches an entire subtree and loses to any pattern that matches a subset of it.
- Matching is on the cleaned, decoded path; specificity never depends on registration order.

Two patterns can also conflict outright: neither is more specific than the other, yet they overlap, as with `/users/{id}/settings` and `/users/admin/{section}`. This is a configuration error. The router surfaces it when it rebuilds, the rebuild fails, and the previous route set stays in service.



## Handler Functions


Endpoint handlers use the `http` module to access request and response objects. See [HTTP Module](lua/http/http.md) for the request and response API reference.

```lua
local http = require("http")
local funcs = require("funcs")

local function handler()
    local req, req_err = http.request()
    if req_err then return nil, req_err end
    local res, res_err = http.response()
    if res_err then return nil, res_err end

    local user_id, param_err = req:param("id")
    if param_err then return nil, param_err end
    local user, call_err = funcs.call("app.users:get_user", user_id)
    if call_err then return nil, call_err end

    local status_err = res:set_status(http.STATUS.OK)
    if status_err then return nil, status_err end
    local write_err = res:write_json(user)
    if write_err then return nil, write_err end
    return true
end

return { handler = handler }
```



## Middleware Options


Middleware options use dot notation with the middleware name as prefix:

```yaml
middleware:
  - cors
  - ratelimit
  - token_auth
options:
  cors.allow.origins: "https://app.example.com"
  cors.allow.methods: "GET,POST,PUT,DELETE"
  ratelimit.requests: "100"
  ratelimit.window: "1m"
  token_auth.store: "app:tokens"
  token_auth.header.name: "Authorization"
```

Post-match middleware uses `post_options`:

```yaml
post_middleware:
  - endpoint_firewall
post_options:
  endpoint_firewall.action: "access"
```



## Pre-Handler and Post-Match Middleware


**Pre-handler** (`middleware`) runs after the server selects a route but before route parameters and endpoint metadata are attached to the request context:
- CORS (handles OPTIONS preflight)
- Compression
- Rate limiting
- Real IP detection
- Token authentication (context enrichment)

**Post-match** (`post_middleware`) runs after route parameters and endpoint metadata are attached:
- Endpoint firewall (needs route info for authorization)
- Resource firewall
- WebSocket relay

```yaml
middleware:        # Before endpoint metadata: matched routes only
  - cors
  - compress
  - token_auth     # Enriches context with actor/scope

post_middleware:   # Post-match: matched routes only
  - endpoint_firewall  # Uses actor from token_auth
```

<tip>
Token authentication belongs in the pre-handler chain because it enriches the request context before authorization. Authorization middleware such as <code>endpoint_firewall</code> belongs in the post-match chain because it needs the matched endpoint ID. Unmatched requests do not run either router chain.
</tip>



## Router and Endpoint Wiring


This example defines the list handler entry. The `app:get_user_by_id` and `app:create_user` function IDs refer to handlers defined elsewhere in the same namespace.

```yaml
version: "1.0"
namespace: app

entries:
  # Server
  - name: gateway
    kind: http.service
    addr: ":8080"
    lifecycle:
      auto_start: true

  # API Router
  - name: api
    kind: http.router
    meta:
      server: gateway
    prefix: /api/v1
    middleware:
      - cors
      - compress
      - ratelimit
    options:
      cors.allow.origins: "https://app.example.com"
      ratelimit.requests: "100"
      ratelimit.window: "1m"

  # Handler function
  - name: get_users
    kind: function.lua
    source: file://handlers/users.lua
    method: list
    modules:
      - http
      - json
      - sql

  # Endpoints
  - name: list_users
    kind: http.endpoint
    meta:
      router: api
    method: GET
    path: /users
    func: get_users

  - name: get_user
    kind: http.endpoint
    meta:
      router: api
    method: GET
    path: /users/{id}
    func: app:get_user_by_id

  - name: create_user
    kind: http.endpoint
    meta:
      router: api
    method: POST
    path: /users
    func: app:create_user
```



## Protected Routes


The following configuration separates public routes from routes that require authentication and authorization:

```yaml
entries:
  # Public routes (no auth)
  - name: public
    kind: http.router
    meta:
      server: gateway
    prefix: /api/public
    middleware:
      - cors

  # Protected routes
  - name: protected
    kind: http.router
    meta:
      server: gateway
    prefix: /api
    middleware:
      - cors
      - token_auth
    options:
      token_auth.store: app:tokens
    post_middleware:
      - endpoint_firewall
```



## See Also


- [Server](http/server.md) - HTTP server configuration
- [Static Files](http/static.md) - Static file serving
- [Middleware](http/middleware.md) - Available middleware
- [HTTP Module](lua/http/http.md) - Lua HTTP API



## Navigation

Previous: "HTTP Server" (http/server)
Next: "HTTP Endpoints" (http/endpoint)
