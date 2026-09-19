# "Static Files"

_Path: en/http/static_

> "Serve SPAs, assets, and user uploads from filesystem entries with http.static."

## Table of Contents

- Static Files

## Content

# Static Files


An `http.static` handler mounts directly on a server and serves SPAs, assets, or user uploads from a filesystem entry.

**Classification: static-handler reference.** The YAML blocks assume the named
HTTP server exists. In these host-authored examples, relative `fs.directory`
paths are resolved from the project working directory. Module-owned entries
instead resolve relative paths from the owning module's source root unless
configured with `base: project`. The referenced files must be created separately.



## Configuration


```yaml
- name: static
  kind: http.static
  meta:
    server: gateway
  path: /
  fs: app:public
  static_options:
    spa: true
    index: index.html
    cache: "public, max-age=3600"
```

| Field | Type | Description |
|-------|------|-------------|
| `meta.server` | Registry ID | Parent HTTP server |
| `path` | string | URL mount path (must start with `/`) |
| `fs` | Registry ID | Filesystem entry to serve from |
| `static_options.spa` | bool | SPA mode - serve index for unmatched paths |
| `static_options.index` | string | Index file (required when `spa=true`) |
| `static_options.cache` | string | Cache-Control header value |
| `middleware` | []string | Middleware chain |
| `options` | map | Middleware options (dot notation) |

<tip>
Static handlers can be mounted to any path on the server. Multiple handlers can coexist—mount assets at <code>/static</code> and an SPA at <code>/</code>.
</tip>



## Filesystem Integration


Static files are served from filesystem entries. Any filesystem type works:

```yaml
entries:
  # Local directory
  - name: public
    kind: fs.directory
    directory: ./public

  # Static handler
  - name: static
    kind: http.static
    meta:
      server: gateway
    path: /static
    fs: public
```

Request `/static/css/style.css` serves `./public/css/style.css`.

To serve a subdirectory, point the `fs` reference at a filesystem entry rooted there—for example an `fs.directory` with `directory:` set to the subdirectory:

```yaml
entries:
  - name: content
    kind: fs.directory
    directory: ./app/documentation/html

  - name: docs
    kind: http.static
    meta:
      server: gateway
    path: /docs
    fs: content
```



## SPA Mode


Single Page Applications need all routes to serve the same index file for client-side routing:

```yaml
- name: spa
  kind: http.static
  meta:
    server: gateway
  path: /
  fs: app:frontend
  static_options:
    spa: true
    index: index.html
```

| Request | Response |
|---------|----------|
| `/app.js` | Serves `app.js` (file exists) |
| `/users/123` | Serves `index.html` (SPA fallback) |
| `/api/data` | Serves `index.html` (SPA fallback) |

<note>
When <code>spa: true</code>, the <code>index</code> file is required. Existing files are served directly; all other paths return the index file.
</note>



## Cache Control


Set appropriate caching for different asset types:

```yaml
entries:
  - name: app_fs
    kind: fs.directory
    directory: ./dist

  # Versioned assets - cache forever
  - name: assets
    kind: http.static
    meta:
      server: gateway
    path: /assets
    fs: app_fs
    static_options:
      cache: "public, max-age=31536000, immutable"

  # HTML - short cache, must revalidate
  - name: app
    kind: http.static
    meta:
      server: gateway
    path: /
    fs: app_fs
    static_options:
      spa: true
      index: index.html
      cache: "public, max-age=0, must-revalidate"
```

Common cache patterns:

- **Versioned assets**: `public, max-age=31536000, immutable`
- **HTML/index**: `public, max-age=0, must-revalidate`
- **User uploads**: `private, max-age=3600`



## Middleware


Apply middleware for compression, CORS, or other processing:

```yaml
- name: static
  kind: http.static
  meta:
    server: gateway
  path: /
  fs: app:public
  middleware:
    - compress
    - cors
  options:
    compress.level: "best"
    cors.allow.origins: "*"
```

Middleware wraps the static handler in order—requests pass through each middleware before reaching the file server.

<warning>
Path matching is prefix-based. A handler at <code>/</code> catches all unmatched requests. Use routers for API endpoints to avoid conflicts.
</warning>



## See Also


- [Server](http/server.md) - HTTP server configuration
- [Routing](http/router.md) - Routers and endpoints
- [Filesystem](lua/storage/filesystem.md) - Filesystem module
- [Middleware](http/middleware.md) - Available middleware



## Navigation

Previous: "HTTP Middleware" (http/middleware)
Next: "WebSocket Relay" (http/websocket-relay)
