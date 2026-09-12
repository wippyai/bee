# bee.driver.grok

The pure driver binding for the Grok CLI (`grok`), conforming to `bee.driver:driver` and the `bee.driver@1` profile schema.

## Architecture & Responsibilities

`bee.driver.grok` provides declarative launch specifications, configuration projection, and wire protocol normalization for Grok without touching processes, credentials, or live filesystem state:

| Component | Responsibility |
|---|---|
| `launch.lua` | Decodes launch requests and constructs typed CLI argument vectors (`argv`) for fresh turns, resumed sessions, and native PTY windows. |
| `prepare_method.lua` | Driver contract `prepare` entrypoint: validates request and returns declarative `Launch` specification. |
| `dispatch_method.lua` | Driver contract `dispatch` entrypoint: ensures `resume_ref` is present for continued turns and returns declarative `Launch` specification. |
| `configuration.lua` | Projects `.grok/config.toml` delivery containing gateway MCP server configuration and permission allow rules, verified with SHA-256 digests. |
| `configure_method.lua` | Driver contract `configure` entrypoint: strictly refuses provider configurations and gateway hooks, delivering `.grok/config.toml` when a gateway is present. |
| `protocol.lua` | State machine normalizer converting Grok `streaming-json` NDJSON envelopes into standard thread observations (`session.state`, `turn.signal`, `text`, `tool.call`, `tool.result`, `notice`, `extension`). |
| `normalize_method.lua` | Driver contract `normalize` entrypoint: handles envelope decoding, state persistence across chunks, and stream termination / EOF handling. |

## Profiles

Grok exports three profiles declared under `meta.driver` (`bee.driver@1`):

1. **`session` (Default)**:
   - Mode: `session`
   - Protocol: `stream-json` (`streaming-json-1`)
   - Inbound: `[next_turn]`
   - Resume strategy: `per-process` (`-r <resume_ref>`), non-portable
   - Answer path: `accumulate` via `bee.driver.grok:protocol`
   - Input readiness: `{strategy: none}` (no synthetic protocol init)
   - Permission exchange: `{mode: none}`
   - MCP client transports: `stdio`, `streamable_http`, `sse`
   - Isolation environment: `[HOME, GROK_HOME]`, private home enabled

2. **`batch`**:
   - Mode: `batch`
   - Protocol: `stream-json` (`streaming-json-1`)
   - Single autonomous turn with bounded `--max-turns`
   - Same answer accumulation, resume strategy, and isolation as `session`

3. **`window`**:
   - Mode: `window`
   - Protocol: `pty` (`native-window-1`)
   - Direct interactive terminal attached to the Grok TUI
   - Readiness: `terminal:attached`
   - Answer path: `{strategy: none}`
   - Resume: `{strategy: none}`

## CLI Grammar & Flag Semantics

The driver targets the native `grok` CLI syntax (verified on Grok 1.0.24):

- **Prompt Quoting & Flag Disambiguation**:
  - For standard brief prompts, Grok takes `-p <prompt>`.
  - If `<prompt>` begins with `-` (e.g. `--version`, `-p flag`), passing `-p "<prompt>"` causes the CLI parser to reject the prompt as a missing option argument. The driver detects leading dashes and automatically switches to `--single=<prompt>`.
  - For `window` mode, prompts are passed after a `--` positional separator (`grok [options] -- <prompt>`), ensuring prompt text is never parsed as a CLI flag.
- **Headless Streaming**:
  - Headless turns pass `--output-format streaming-json`.
- **Permission Mode**:
  - Managed via `--permission-mode <mode>` (`default`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`, `plan`).
  - In `window` mode, `--permission-mode` is omitted when set to `default` to preserve interactive defaults.
- **Turn Limits**:
  - Structured modes support `--max-turns <N>` (bounded between 1 and 32). Max turns are rejected for `window` mode.
- **Model & Reasoning**:
  - Model selection passes `--model <model>`.
  - Reasoning effort passes `--reasoning-effort <effort>` (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`). The alias `reasoning_effort` is accepted in requests.
- **Session Continuation**:
  - Resumed sessions pass `-r <resume_ref>`. Resume references beginning with `-` are rejected as CLI injection attempts.
- **MCP Tool Permissions**:
  - When gateway tools are supplied, Grok is invoked with `--allow "MCPTool(bee__*)"`.

## Configuration & MCP Delivery

Grok manages configuration and MCP servers via TOML files in `$GROK_HOME/config.toml` or `./.grok/config.toml`:

- **Provider Configuration**: Grok does not accept external provider configurations (`request.provider_ref ~= nil or request.provider ~= nil` returns an error).
- **Gateway Hooks**: Grok HTTP hooks require HTTPS endpoints; plain HTTP hook scripts or shell curls are not fabricated. Gateway requests containing hooks are strictly refused (`request.gateway.hooks > 0` returns an error).
- **Gateway MCP Delivery**: When a gateway descriptor is provided, `configure` projects a `.grok/config.toml` file (`revision = "bee.grok-config@1"`, `provider_ref = "bee:gateway_endpoint"`) with content:
  ```toml
  # generated by bee bee.grok-config@1
  [permission]
  allow = [
      "MCPTool(bee__*)",
  ]

  [mcp_servers.bee]
  url = "http://<endpoint>/mcp/<action_id>"
  enabled = true

  [mcp_servers.bee.headers]
  Authorization = "Bearer ${<token_environment>}"
  ```
  The projection verifies content bounds (maximum 8192 bytes) and computes a canonical SHA-256 digest.

  The generated `${TOKEN_ENVIRONMENT}` header interpolation is a configuration projection only. It has not been exercised against an authenticated Grok MCP turn, so it remains unproven until that acceptance exists.

## Protocol Normalization (`streaming-json`)

Grok's native `streaming-json` format emits newline-delimited JSON envelopes:

1. **Turn & Session Lifecycle**:
   - Grok does not emit a synthetic `init` event. The normalizer auto-starts the turn and session upon receiving the first envelope:
     - `session.state`: `started` (or `resumed` when `resumed = true`), binding `state.session_id` if present on the envelope.
     - `turn.signal`: `started`.
2. **Reasoning (`thought`)**:
   - Emits `text` observations on segment `reasoning`, operation `append`, channel `reasoning_summary`.
3. **Answer Stream (`text`)**:
   - Emits `text` observations on segment `answer`, operation `append`, channel `answer`.
   - Text chunks are accumulated in `state.answer` only up to 12,288 bytes. Larger answers remain represented by their text observations; the retained terminal answer is omitted so checkpoint state stays bounded.
4. **Tool Calls (`tool_call`)**:
   - Emits `tool.call` observations with `call_id`, `tool_name`, and JSON-encoded input.
5. **Tool Results (`tool_call_update`)**:
   - Only explicit `completed`, `failed`, and `error` update statuses emit `tool.result` observations. This conservative mapping is covered by the component fixture; no authenticated Grok stream was run.
   - Other updates remain `grok.tool_call_update` extensions; they cannot manufacture a completed tool result.
6. **Usage (`usage`)**:
   - Tracks `input_tokens`, `output_tokens`, and `cached_tokens`.
7. **Extensions (`available_commands`, `plan`)**:
   - Emits `extension` observations preserving envelope payload JSON.
8. **Errors (`error`)**:
   - Emits `notice` observations with level `warning` and code `provider_error`.
9. **Terminal Turn Signal (`end`)**:
   - Only the observed `end_turn` and `max_turn_requests` stop reasons emit `turn.signal` ended with `reported_outcome = "succeeded"`. Missing or unrecognized reasons remain `uncertain`; process exit is not used to turn them into success.
   - Stop reasons `cancelled` / `canceled` emit `reported_outcome = "cancelled"`.
   - Explicit errors emit `reported_outcome = "failed"` with a `turn_failed` fault. Unknown reasons emit `uncertain` with an `unrecognized_stop_reason` fault.
   - Sets `state.terminal` with the bounded retained answer, the first valid `sessionId` observed during the turn, usage metrics, and an optional fault. A later, different session ID is recorded as a warning and cannot replace the resume reference.
10. **Post-Terminal & EOF Handling**:
    - Envelopes arriving after `state.terminal` emit `notice` with code `after_terminal`.
    - If the stream closes (EOF) without an `end` envelope, `finish` emits `turn.signal` ended with `uncertain` and sets terminal outcome to `uncertain` with a `stream_ended` fault.

## Verification

The driver implementation is strictly typed and verified using Wippy's type checker:

```bash
/home/wolfy-j/.wippy/bin/wippy lint --set lua.type_system.enabled=true --set lua.type_system.strict=true --ns "bee.driver.grok"
```

Unit test coverage is implemented under `tests/lua/driver/grok/`:
- `launch_test.lua`: Parameter validation, option escaping, `--single=` handling, window mode argument positioning, and prepare/dispatch methods.
- `configuration_test.lua`: TOML rendering, SHA-256 digest determinism, oversized configuration rejection, provider rejection, and hook refusal.
- `protocol_test.lua`: Full stream lifecycle, auto-start, reasoning, text accumulation, tool call/results, terminal reporting, post-terminal envelopes, and EOF handling.
