# "Network Overlays"

_Path: en/system/network_

> "Route outbound connections and bind listeners through SOCKS5, Tor, Tailscale, or I2P overlays."

## Table of Contents

- Network Overlays

## Content

# Network Overlays


Network overlay entries route outbound connections or bind listeners through SOCKS5, Tor, Tailscale, or I2P. A selected overlay propagates across function, process, and HTTP boundaries.

This page is a configuration reference. The YAML fences are entry or application-config fragments and assume the external proxy, tailnet, or I2P SAM service already exists.



## Entry Kinds


| Kind | Description |
|------|-------------|
| `network.socks5` | Generic SOCKS5 proxy (also covers Tor's SOCKS5 listener) |
| `network.tailscale` | Tailscale tsnet overlay node |
| `network.i2p` | I2P SAM v3 bridge |



## SOCKS5


```yaml
- name: proxy
  kind: network.socks5
  host: 127.0.0.1
  port: 1080
  username: "optional"
  password: "optional"
  isolate_streams: false
```

| Field | Type | Description |
|-------|------|-------------|
| `host` | string | Proxy host |
| `port` | int | Proxy port (1-65535) |
| `username` | string | Optional SOCKS5 auth |
| `password` | string | Optional SOCKS5 auth |
| `isolate_streams` | bool | Per-connection random credentials (Tor stream isolation) |

`host` and `port` are required. `isolate_streams` defaults to `false`. When
isolation is enabled, the runtime generates a new username and password for
each dial instead of using the configured credentials.



## Tailscale


```yaml
- name: tailnet
  kind: network.tailscale
  hostname: "wippy-node"
  auth_key: ${env:TS_AUTHKEY}
  ephemeral: false
  control_url: ""
```

| Field | Type | Description |
|-------|------|-------------|
| `hostname` | string | tsnet node name (used in per-node state directory) |
| `auth_key` | string | Tailnet auth key — inline or `${env:NAME}` resolved via the [env registry](system/env.md) |
| `state_dir` | string | Override for tsnet state directory |
| `control_url` | string | Alternate coordination server |
| `ephemeral` | bool | Register as an ephemeral tailnet node |

`auth_key` is required (supply it directly or via `${env:NAME}`). The legacy `auth_key_env` directive resolves the same way but is deprecated; prefer `auth_key: ${env:NAME}`.

The tsnet hostname defaults to `wippy`. When `state_dir` is omitted, the runtime
uses `<network_service.state_dir>/tailscale/<node>`, where `<node>` is the
configured hostname or, if no hostname is configured, the registry entry name.



## I2P


```yaml
- name: i2p_bridge
  kind: network.i2p
  host: 127.0.0.1
  port: 7656
  session_name: "wippy"
```

| Field | Type | Description |
|-------|------|-------------|
| `host` | string | SAM v3 bridge host |
| `port` | int | SAM v3 bridge port |
| `session_name` | string | Optional session identifier |

`host` and `port` are required. `session_name` defaults to `wippy` and is used
as the prefix for per-dial and per-listener SAM session IDs.



### On `http.service`


Bind the server listener through an overlay (Tailscale, I2P):

```yaml
- name: gateway
  kind: http.service
  addr: ":8080"
  network: app.net:tailnet
```

SOCKS5 does not support inbound listening — use it only for outbound dials.



### From Lua


Route a called function or spawned process through an overlay using `with_options`:

```lua
local funcs = require("funcs")

local caller, err = funcs.new():with_options({ network = "app.net:proxy" })
if err then return nil, err end
local result, call_err = caller:call("app.api:fetch_data")
if call_err then return nil, call_err end
```

```lua
local process = require("process")

local pid, err = process.with_options({ network = "app.net:tailnet" })
    :spawn_monitored("app.workers:probe", "app:processes")
if err then return nil, err end
```

Constructing the process spawner with custom options also requires `process.context` on `context`. A denial raises a Lua error before the spawner is returned; `network.select` is then checked separately for the selected network ID.

The `http_client` module accepts the same overlay selection on per-call options under the key `overlay_network`.



## Inheritance


Overlay selection propagates through the call stack. A function called through
`funcs.new():with_options({network=...})` uses the overlay for inner dials,
nested calls, and spawned processes unless a new boundary selects another
overlay. An empty `network` option means "no override"; it does not clear an
inherited overlay or the application default.

For a function call, runtime options override the function entry's
`meta.options` before network selection. At a new function or process boundary,
a non-empty `options.network` is selected first. If it is absent,
`network_service.default_network` is selected when configured; if neither is
present, the inherited frame selection remains. A selected ID must already be
registered. An unknown ID fails the call or spawn instead of falling back to
the host network.

Ambient inheritance bypasses the descendant's own `network.select` deny rules. Only explicit selection at a Lua edge is gated.



## App Configuration


Overlay drivers read app-wide settings from a `network_service:` block in `.wippy.yaml`:

```yaml
network_service:
  state_dir: .wippy/net          # base dir for driver state (Tailscale keys, etc.)
  default_network: app.net:tailnet  # overlay applied when no call sets one
```

| Field | Default | Description |
|-------|---------|-------------|
| `state_dir` | `.wippy/net` | Driver state directory. Relative paths resolve against the boot config dir. |
| `default_network` | — | Registry ID of an overlay applied to any task or process that does not pin its own network via options. |



## Raw Dials


Overlay selection is not limited to Lua edges. Dials made through the runtime network service — the WASM [`socket` host](wasm/hosts.md#socket) and the `wasi:sockets` dispatcher — read the overlay off the frame and route through it, whether it was set by `with_options`, by `meta.options.network` on the entry, or by `network_service.default_network`.

The private-IP gate behaves differently on that path. A direct dial resolves the target and checks every resulting address against `socket.private_ip`. With an overlay selected, only a literal IP address in the target is checked; host names are handed to the overlay to resolve, so the local resolver is never consulted and no check is made on what it would have returned.

When an overlay is selected but the context carries no network registry, the dial fails with `network "<id>" selected without a network registry`.



## Updating Overlays


Overlay entries are replaced on registry update. The driver builds the replacement before switching to it; if creation fails, the existing overlay continues running. A successful swap is atomic for new lookups, then the previous service is closed. Work already using the previous service can therefore observe that closure.



## Permissions


| Action | Resource | Description |
|--------|----------|-------------|
| `network.select` | Network registry ID | Explicit overlay selection at `funcs.call`, `process.spawn`, `http_client` |
| `network.bind` | Network registry ID | Binding an `http.service` listener through an overlay (the `network:` field) |
| `socket.connect` | `host:port` | Any outbound dial through the network service |
| `socket.listen` | `host:port` | Binding a TCP listener or a UDP socket through the network service |
| `socket.resolve` | Host name | DNS resolution through the network service |
| `socket.private_ip` | IP address | Reaching a loopback, private, link-local or unspecified address |

Deny `network.select` on a scope to stop code inside it from choosing an overlay explicitly. Inherited overlays are unaffected — they were authorized at the caller. `network.bind` is checked when a server with a `network:` overlay starts its listener.

The `socket.*` permissions are checked by the network service itself. `socket.connect`, `socket.listen` and `socket.resolve` are checked before any overlay routing, so they apply equally to clearnet and overlay traffic; `socket.private_ip` narrows to literal addresses once an overlay is selected, as described under [Raw Dials](system/network.md#raw-dials).



## See Also


- [Security](system/security.md) - Policies and actors
- [HTTP Service](http/server.md) - Server binding
- [HTTP Client](lua/http/client.md) - Per-call overlay selection
- [Host Functions](wasm/hosts.md) - WASM socket imports



## Navigation

Previous: "Queue" (system/queue)
Next: "Filesystem" (system/filesystem)
