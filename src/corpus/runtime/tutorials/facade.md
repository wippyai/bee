# "Frontend Facade"

_Path: en/tutorials/facade_

> "Serve and configure the Wippy Web Host from a backend application with wippy/facade."

## Table of Contents

- Frontend Facade

## Content

# Frontend Facade


Use `wippy/facade` to serve the Wippy Web Host from a backend application. The facade loads the frontend bundle from a CDN and configures it through a JSON endpoint served by the application, without requiring a frontend build step. Dependency parameters control branding, theming, and feature flags.

**Classification:** Partial integration recipe. It completely configures and verifies
the facade shell and config endpoint, but it does not invent an authentication system
or the application APIs consumed by the Web Host.



## What You'll Build


A backend app that serves the Wippy UI:

1. An HTTP server and public router.
2. A `wippy/facade` dependency connected to the server and router, with custom branding.
3. The facade shell at `/` and its configuration at `/api/public/facade/config`.



## Prerequisites


- Wippy runtime `v0.3.32a` and a project created with `wippy init` or the
  [Wippy application template](https://github.com/wippyai/app).
- For browser rendering, a same-origin login flow that obtains a real backend token
  and stores `{"token":"..."}` under the localStorage key `@wippy_token_info`.
  The facade does not issue or validate that token.
- The facade installed:

  ```bash
  wippy add wippy/facade@0.6.37
  wippy install
  ```



## How It Works


1. The shell is rendered from the facade's template and served at `/` by your HTTP
   server; its assets and the deep-link fallback come from a static mount on the same server.
2. On load it fetches `GET /api/public/facade/config`.
3. It reads `@wippy_token_info` from `localStorage`, redirecting to `login_path`
   only when the item is absent or cannot be parsed as JSON.
4. It imports the Web Host bundle from the CDN (`facade_url + '/module.js'`) and calls
   `initWippyApp(...)` with the config.

The application serves the shell and its configuration; the UI bundle comes from the CDN.



## Dependencies


The facade requires an `http.service` for the shell and an `http.router` for its configuration endpoint. Other parameters customize branding and behavior.

```yaml
version: "1.0"
namespace: app

entries:
  - name: gateway
    kind: http.service
    addr: ":8087"
    lifecycle:
      auto_start: true

  - name: api.public
    kind: http.router
    meta:
      server: app:gateway
    prefix: /api/public

  - name: facade
    kind: ns.dependency
    component: wippy/facade
    version: "*"
    parameters:
      - name: server
        value: app:gateway
      - name: router
        value: app:api.public
      - name: app_title
        value: Verify App
```

The shell requests its config, theme script, and CSS variables under
`/api/public/facade/`, so the public router's prefix must be `/api/public`.



## Run It


```bash
wippy run
```

The shell is served at the server root, and the config endpoint returns the runtime
configuration:

```bash
curl http://localhost:8087/api/public/facade/config
```

Selected fields from the response are shown below:

```json
{
  "facade_url": "https://web-host.wippy.ai/webcomponents-1.0.58",
  "iframe_origin": "https://web-host.wippy.ai",
  "iframe_url": "https://web-host.wippy.ai/webcomponents-1.0.58/iframe.html?waitForCustomConfig",
  "module_file": "/module.js",
  "mode": "compat",
  "login_path": "/login.html",
  "themeMode": "auto",
  "themePersist": "none",
  "themeStorageKey": "@wippy-theme-mode",
  "env": { "APP_API_URL": "", "APP_AUTH_API_URL": "", "APP_WEBSOCKET_URL": "" },
  "themeMode": "auto",
  "themePersist": "none",
  "themeStorageKey": "@wippy-theme-mode",
  "theming": {
    "host": { "i18n": { "app": { "title": "Verify App", "icon": "wippy:logo", "appName": "Wippy AI" } } }
  },
  "hostConfig": {
    "showAdmin": true, "allowSelectModel": false, "hideNavBar": false,
    "disableRightPanel": false, "startNavOpen": false, "hideSessionSelector": false,
    "renderEngine": "iframe", "session": { "type": "non-persistent" }, "history": "hash"
  }
}
```

The `app_title` parameter appears as `theming.host.i18n.app.title` in the response.

Also fetch the root document:

```bash
curl http://localhost:8087/
```

It should return an HTML shell that fetches the config endpoint and checks
`@wippy_token_info`. These two HTTP checks verify the recipe without bypassing auth.



## Browser Authentication and Rendering


The facade's localStorage contract is origin-scoped. A login page on another port or
hostname cannot populate the token for `http://localhost:8087`. After a successful
same-origin token exchange, the login page writes the real token and returns to the
shell:

```js
localStorage.setItem('@wippy_token_info', JSON.stringify({token: result.token}));
window.location.assign('/');
```

The shell reads the token, imports
`https://web-host.wippy.ai/webcomponents-1.0.56/module.js`, and passes the token to the
Host. Rendering is complete only when the browser shows the Host without redirecting
and its API requests authenticate successfully. Do not use a placeholder token merely
to suppress the redirect: the shell does not validate it, so the failure only moves to
the first protected API request.



## Configuration


Parameters are passed as dependency `parameters` (values are strings; JSON values are
JSON-encoded strings). Common ones:

| Parameter | Purpose |
|---|---|
| `server` / `router` | _(required)_ HTTP server and public router |
| `app_title` / `app_name` / `app_icon` | Branding (icon is an Iconify ref) |
| `show_admin` / `hide_nav_bar` | Feature flags (`"true"` / `"false"`) |
| `login_path` | Where the shell redirects when no auth token is present |
| `session_type` | `non-persistent` or `cookie` |
| `history_mode` | `hash` or `browser` |
| `css_variables` | JSON string of CSS custom properties, e.g. `'{"--p-primary":"#6366f1"}'` |
| `fe_facade_url` | CDN bundle URL (pinned per facade release; leave default unless overriding) |

Two values are derived at runtime from `PUBLIC_API_URL` rather than parameters: the API
base URL and the WebSocket URL (`http`→`ws`, `https`→`wss`). The facade reads it through
the env registry, so declare it as an `env.variable` in your app. If unset, the browser
falls back to `window.location.origin`.



## Limitations


- The facade does not provide authentication. It expects an auth flow that writes a
  token to `localStorage`; without one it redirects to `login_path`. Pair it with
  `userspace/users` or your own auth.
- The UI bundle loads from the CDN (`fe_facade_url`), so the user's browser must be
  able to reach that URL.



## Troubleshooting


- A redirect loop to `/login.html` means the current origin has no parseable
  `@wippy_token_info` item. Complete the real login flow on the same origin. A
  parseable object with a missing or empty `token` suppresses this redirect but
  still fails when the Host reaches a protected API.
- HTTP 404 from `/api/public/facade/config` means the router prefix is not
  `/api/public` or the `router` dependency parameter points at another entry.
- A config response with the right values but a blank shell usually means the browser
  cannot load `facade_url + module_file`; check the browser network panel and CDN
  policy.
- Authenticated API errors after the Host renders belong to the application's API and
  token validation layer, not to the facade shell.



## Next Steps


- [Hello World](tutorials/hello-world.md) — Minimal project layout
- [Authentication](tutorials/auth.md) — Add the login flow expected by the shell
- [HTTP Endpoints](http/endpoint.md) — Routers, static files, and handlers



## Navigation

Previous: "Crypto Ticker" (tutorials/auth)
Next: "Network Overlays" (tutorials/network)
