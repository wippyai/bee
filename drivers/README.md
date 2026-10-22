# bee/drivers

Declarative, installable drivers for agent CLIs: Claude Code, Codex,
Antigravity (agy), Muse, Grok and opencode. Each driver is a set of registry
entries — a CLI descriptor (command, options, login evidence, version probe),
capability profiles (batch, session and window modes, protocol, resume,
interrupt, MCP, hooks, sandbox), and a contract binding — plus a codec that
turns the CLI's output stream into typed records.

A driver never runs anything. It turns an admitted request into a declarative
launch (executable, arguments, environment names, stdin, required files,
provider home, readiness) and normalizes output. The host decides where the
launch runs — natively or in a container — and passes that placement's
isolation in each request.

## Host requirements

| Requirement | Value |
|---|---|
| `activation` | the host's `bee.harness_activation` entry naming the driver bindings it activates |
| `host_environment` | `env.storage` with the host variables drivers read (CLI executable paths, configuration homes) |
| `entered_values` | `env.storage` with credential values a person entered for the drivers' credential sources |

## Contract

`bee.drivers:driver`, one binding per CLI:

- `prepare` — the launch for `{profile_id, brief, <option values>, isolation}`.
- `dispatch` — the input for a turn on a running attempt.
- `normalize` — one output envelope into observations and, at the end of a turn, a terminal report (`outcome`, `answer`, `resume_ref`, `usage`, `error`).
- `configure` — arguments and private-home files for the selected options, MCP gateway and hooks.

`bee.drivers:locate_facet` — `locate` checks executable, login evidence and platform.

`isolation` is `{kind = "native" | "container", credentials, mounted_roots, network, option_ceilings}`. A request without it gets only the descriptor's own option ceilings.

## Kit

`bee.drivers.kit:kit` is the host-facing library; attach the
`bee.drivers.kit:client` policy to the entries that use it.

```lua
local kit = require("kit") -- imports: kit: bee.drivers.kit:kit

local drivers = kit.catalog()                 -- activated drivers, profiles, declared options
local launch = kit.prepare("bee.drivers.claude.binding:binding",
    {profile_id = "batch", brief = "say pong", model = "sonnet", isolation = isolation})
local stream = kit.stream("bee.drivers.claude.binding:binding")
local step = stream:feed(chunk)               -- {observations, terminal?}
local last = stream:finish()                  -- settles a stream that ended early
```

## Development

```sh
cd test
wippy update
wippy test
```

`test/` is a standalone host: file environment storages, an activation entry
for every shipped binding and recorded CLI streams under `test/fixtures`.

License: MIT.
