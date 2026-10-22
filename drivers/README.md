# bee/drivers

Declarative, installable drivers for agent CLIs: Claude Code, Codex,
Antigravity (agy), Muse, Grok and opencode. Each driver is a set of registry
entries — a CLI descriptor (command, options, login evidence, version probe),
capability profiles (batch, session and window modes, protocol, resume,
interrupt, MCP, hooks, sandbox), and a contract binding — plus a codec that
turns the CLI's output stream into typed records.

A driver never runs anything. It turns a request into a declarative launch
(executable, arguments, stdin, environment, files under the CLI's home) and
normalizes output. The host decides where the launch runs and describes that
placement in each request.

## Host requirements

| Requirement | Value |
|---|---|
| `activation` | the host's `bee.harness_activation` entry naming the driver bindings it activates |
| `host_environment` | `env.storage` with the host variables drivers read (CLI executable paths, configuration homes) |
| `entered_values` | `env.storage` with credential values a person entered for the drivers' credential sources |

## Library

`bee.drivers:drivers` is the host-facing surface. Hosts name drivers by id;
bindings, descriptors and codecs stay behind it. Errors carry kinds
(`errors.NOT_FOUND`, `errors.INVALID`, `errors.INTERNAL`, `errors.UNAVAILABLE`).

```lua
local drivers = require("drivers") -- imports: drivers: bee.drivers:drivers

local list = drivers.list()        -- {id, title, executable, profiles, options, capabilities, unattended, credentials}
local launch, err = drivers.launch("claude", {
    brief = "say pong",
    home = "/home/node",                   -- the CLI's HOME inside the placement
    placement = {kind = "container", network = "bridge",
        mounts = {{resource = "workspace", target = "/workspace", access = "write"}},
        allows = {"bypass", "network", "write-anywhere"}},
    unattended = true,                     -- no person answers permission prompts
    options = {model = "sonnet"},
    gateway = gateway,                     -- optional: the host's MCP + hook endpoint
})
-- launch = {executable, argv, stdin, stdin_eof, environment, files, readiness}

local reader = drivers.reader("claude")
local step = reader:feed(chunk)            -- {observations, terminal?, problems}
local last = reader:finish()               -- settles the stream at its end
```

**Access.** The library runs under its caller's scope. A host grants
`registry.get` and `registry.snapshot`, `contract.get`, `contract.open`,
`contract.call` and `funcs.call` on exactly: `bee.drivers:host`,
`bee.drivers:driver`, its activation entry, `bee.drivers.binding:configure`,
the method name `prepare`, and for each activated driver its
`binding:binding`, `descriptor:cli`, `profiles:profiles` and
`credentials:credential_format` entries. `test/src/drivers` launches under
exactly this grant.

**Placement.** `allows` names the capabilities the placement admits
(`prompt`, `edit`, `automatic`, `deny-unapproved`, `read`, `bypass`,
`write-admitted`, `write-anywhere`, `network`, `request-approval`,
`no-approvals`, `profile-option`). Each descriptor maps its option values to
these capabilities, so hosts never name driver options to bound them.

**Unattended.** Each descriptor declares the option values its CLI runs with
when no person answers prompts; the placement must allow their capabilities.

**Gateway.** `{endpoint, action_id, tools, hooks, token_environment,
hook_token_environment?, hook_command?}`: the one MCP server and hook target
the host serves at `http://{endpoint}/mcp/{action_id}` and
`http://{endpoint}/hook/{action_id}`. Tokens travel only as the named
environment variables.

**Files.** Paths are relative to `home`. A file with `secret_fields` takes
the named environment values at those JSON paths; a file with `composition`
merges onto the existing file at `composition.base_path`.

## Contract

`bee.drivers:driver`, one binding per CLI, for hosts that need the raw
steps: `prepare`, `dispatch`, `normalize`, `configure`, and
`bee.drivers:locate_facet` `locate`.

## Development

```sh
cd test
wippy update
wippy test
```

`test/` is a standalone host: file environment storages, an activation entry
for every shipped binding and recorded CLI streams under `test/fixtures`.

License: MIT.
