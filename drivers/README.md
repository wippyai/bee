# bee/drivers

Declarative, installable drivers for agent CLIs: Claude Code, Codex,
Antigravity (agy), Muse, Grok, opencode and Pi. Each driver is a set of registry
entries — a CLI descriptor (command, options, login evidence, version probe),
capability profiles (batch, session and window modes, protocol, resume,
interrupt, MCP, hooks, sandbox), and a contract binding — plus a codec that
turns the CLI's output stream into typed records.

A driver never runs anything. It turns a request into a declarative launch
(executable, arguments, stdin, environment, files under the CLI's home) and
normalizes output. The host decides where the launch runs and describes that
placement in each request.

A window-only CLI declares only what it has: its `provider`, `executable`,
`version_probe`, `configure`, `options` and a `window` launch template. An
absent `login_evidence` means the CLI needs no account; an absent `platform`
admits every platform; `json_paths`, `flags` and `provider_home` default to
empty; `codec` is required only with a `first_turn` or `resume` template.

## Personal use of subscription logins

A driver can run a CLI with the login a person made on their own machine
(Claude Pro/Max, ChatGPT plans and similar subscriptions): a login file or a
variable the descriptor lists in `subscription_variables`. Running a
subscription login through a tool like this is not compliant with the
provider's terms except for that person's own, personal use. Do not use it to
serve other people, to run a production service, or to share one subscription
among users: providers may restrict or suspend the account. For production or
multi-user hosts, use an official API key, or point the driver at an endpoint
you operate (see Endpoints). `drivers.list()` reports which credentials are
subscription logins (`credentials.files` and `credentials.subscriptions`) so a
host can say so where a person enters one.

## Host requirements

| Requirement | Value |
|---|---|
| `activation` | the host's `bee.harness_activation` entry naming the driver bindings it activates |
| `host_environment` | `env.storage` with the host variables drivers read (CLI executable paths, configuration homes) |
| `entered_values` | `env.storage` with credential values a person entered for the drivers' credential sources |
| `access_scope` | the security group whose members use the library; it receives `bee.drivers.security:host_access` |

## Library

`bee.drivers:drivers` is the host-facing surface. Hosts name drivers by id;
bindings, descriptors and codecs stay behind it. Errors carry kinds
(`errors.NOT_FOUND`, `errors.INVALID`, `errors.INTERNAL`, `errors.UNAVAILABLE`).

```lua
local drivers = require("drivers") -- imports: drivers: bee.drivers:drivers

local list = drivers.list()        -- {id, title, executable, profiles, options, capabilities, unattended, credentials}
local launch, err = drivers.launch("claude", {
    brief = "say pong",
    home = "/home",                   -- the CLI's HOME inside the placement
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

**Access.** The library runs under its caller's scope. The `access_scope`
requirement names the host group whose members use it; that group receives
`bee.drivers.security:host_access` for the shipped drivers. The host also
grants `registry.get` on its own activation entry. `test/src/drivers` lists,
launches and reads as a member of the bound group.

**Errors.** Every call returns `(value, error)` with a runtime error whose kind
says what went wrong: `NOT_FOUND` (no such activated driver), `INVALID` (the
request, an option or the placement is refused), `CONFLICT` (two activated
bindings declare one driver id), `INTERNAL` (a driver produced something
malformed) or `UNAVAILABLE` (the registry could not be read).

**Types.** `drivers.Driver`, `drivers.LaunchRequest`, `drivers.Launch`,
`drivers.Placement`, `drivers.Gateway`, `drivers.Step`, `drivers.Observation`
and `drivers.Terminal` are exported; reader steps carry decoded records.

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

## Normalized stream records

Text consumers fold observations by `data.segment_id`: `append` adds text;
`replace` and `complete` set its full text. A completed message reuses its
streamed message/block identity. Distinct messages remain distinct even when
their text is identical. IDs are opaque: do not depend on their spelling.
Claude uses the API message ID and zero-based content block index. Pi uses
its `message_start` occurrence and `contentIndex` (the protocol has no stable
message ID at the start). Codex uses item IDs; OpenCode uses message/part IDs.
Agy's step deltas, Grok's text chunks, and Muse's run deltas already have a
single stream identity; their terminal answer summaries do not open segments.
Large full snapshots use a bounded `replace` followed by `append` pieces on
the same ID, preserving every byte. The terminal signal settles the turn.

Every driver's optional `terminal.usage`, and the optional `usage` in an
ended `turn.signal`, have this shape (`?` means optional):

```text
Usage = {
  input_tokens?: integer,
  output_tokens?: integer,
  cached_tokens?: integer,       // cache reads; existing meaning unchanged
  cache_write_tokens?: integer,
  reasoning_tokens?: integer,
  cost_usd?: number,
  cost_decimal?: string, currency?: string,  // existing paired fields
  models?: { [model: string]: ModelUsage }
}
ModelUsage = Usage without models
```

Counters are nonnegative safe integers. Cost is a finite, nonnegative reported
USD amount; drivers do not estimate prices. Reasoning tokens may be a subset
of output tokens; do not add them to output. Unreported fields stay absent;
reported zero values stay present. Models are included only when the stream
identifies them. Totals and per-model usage reflect the provider's respective
reports and need not sum identically (for example, ancillary Claude models).
The existing `cost_decimal`/`currency` contract remains supported.

| Harness | Usage source and aggregation |
|---|---|
| Claude | `result.usage`, `total_cost_usd`, `modelUsage`; completed assistant usage is retained if the result is missing |
| Codex | `turn.completed.usage`; native `token_count` and rollout `event_msg` token-count snapshots supply additional counters and limits; cumulative snapshots replace previous totals |
| Agy | Result aggregate, including `cache_read_tokens` and `thinking_tokens`; completed step usage is retained if the result is missing; `init.model` supplies the model name |
| Grok | Latest `usage`/`end.usage`, including OpenAI-compatible cache and reasoning detail counters |
| Muse | The recorded MSP stream reports no token usage or cost; these stay absent |
| OpenCode | Sum of `step_finish.part.tokens` and `part.cost`, including cache write and reasoning counts; run JSON reports no model identity |
| Pi | Sum of assistant `message_end.message.usage`, including `cacheWrite`, `cost.total`, and `message.model` |

Provider limit observations use one tag and payload:

```text
{
  type: "rate_limit", event_key: string,
  data: { type: "rate_limit", limits: RateLimits }
}
RateLimits = {
  windows: [{
    window: string,
    utilization?: number,       // 0..1, including percentage inputs converted
    status: "allowed" | "warning" | "rejected",
    resets_at?: integer        // epoch seconds
  }],
  overage_status?: "allowed" | "warning" | "rejected",
  overage_disabled_reason?: string,
  is_using_overage?: boolean
}
```

`terminal.rate_limits?: RateLimits` retains the latest provider snapshot,
including on failure or incomplete EOF. Window names follow the provider:
Claude's `five_hour`, `seven_day`, etc., and Codex's `primary`/`secondary`.
`allowed_warning` becomes `warning`; Codex's `used_percent` is divided by
100 (so 1 percent becomes 0.01). Without an explicit status, a fully used
window is rejected and a less used window is allowed. A rejected window
preserves a retryable `rate_limit` failure when the turn fails; an allowed
turn or a rejected overage facility alone does not imply a failed turn.
Other codecs omit rate limits because their admitted streams do not report
provider windows. The same builders and strict decoders serve every codec.

The complete terminal shape is `{outcome, answer?, resume_ref?, usage?,
rate_limits?, error?}`. Existing outcome and fault shapes are unchanged.
`drivers.Usage` and `drivers.RateLimits` export the typed contracts. Both
usage and limit observations also survive the canonical record encoder.
Replay coverage and protocol provenance are in
`test/src/codec_contract_test.lua` and
`test/fixtures/drivers/normalized/manifest.json`, alongside the existing
recorded streams for each harness.

## Endpoints

A host can send a CLI's model traffic to an endpoint it chooses instead of the
vendor's default: an official API, a gateway, or a model server on your own
machines. `drivers.list()` reports each driver's `endpoints`, the protocols it
can reach; a launch passes one endpoint, and the API key reaches the CLI as one
of the driver's credential variables.

```lua
local launch = drivers.launch("codex", {
    brief = "fix the failing test", home = "/home", placement = placement,
    endpoint = {protocol = "openai-responses", base_url = "http://models.example.internal:8000/v1", model = "qwen3-coder"},
})  -- Codex gets a model_providers entry; set OPENAI_API_KEY in the launch environment
```

| Driver | Protocol | How the CLI reaches it |
|---|---|---|
| claude | `anthropic-messages` | `ANTHROPIC_BASE_URL`; key in `ANTHROPIC_API_KEY` |
| codex | `openai-responses` (needs `model`) | a generated `model_providers` entry with `env_key = "OPENAI_API_KEY"` |
| pi | `anthropic-messages` | a generated `models.json` provider override; key in `ANTHROPIC_API_KEY` |

Each driver declares its mappings in its CLI descriptor (`endpoints`), so a new
protocol or driver is data. Plain `http` base URLs are accepted because the
host chose them; prefer `https` outside a private network.

## Pi

Pi 0.73.1 runs the `batch` profile with `-p --mode json --no-session`.
The prompt travels on stdin with EOF. Extension, skill, prompt-template and
context-file discovery are disabled; `--offline` disables startup network
operations and still permits model requests. Pi has no permission prompts or
sandbox. The placement admits `no-approvals`, `write-anywhere` and `network`;
the tools option conservatively requires these rights for every allowlist.
The tools option is a comma-separated string; an empty string renders `--no-tools`. Batch sessions are ephemeral and do
not support resume, MCP or hooks.

The provider option supports exactly these API key providers:

| Provider | Credential variable |
|---|---|
| anthropic | `ANTHROPIC_API_KEY` |
| openai | `OPENAI_API_KEY` |
| google (default) | `GEMINI_API_KEY` |
| openrouter | `OPENROUTER_API_KEY` |
| groq | `GROQ_API_KEY` |
| xai | `XAI_API_KEY` |
| mistral | `MISTRAL_API_KEY` |
| deepseek | `DEEPSEEK_API_KEY` |

These names come from `@mariozechner/pi-ai/dist/env-api-keys.js` in the
0.73.1 package. Pi supports more providers and OAuth, but the frozen
`bee.credential-format@2` admits at most eight variables; this driver projects
only the eight keys above and no login files.

Pi's `docs/models.md` and `dist/core/model-registry.js` support custom
`baseUrl` values in `models.json`. The existing endpoint provider template
renders an `anthropic-messages` endpoint as
`.pi/agent/models.json` with `providers.anthropic.baseUrl` and selects
`--provider anthropic`. The key stays in `ANTHROPIC_API_KEY`; choose a built-in
Anthropic model through the model option. Other endpoint protocols and custom
model definitions are not declared. Both frozen descriptor revisions remain
unchanged. Capture evidence lives in `test/fixtures/drivers/pi/json-1/manifest.json`.

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
