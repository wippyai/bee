# bee.driver.agy

The Antigravity CLI (`agy`) driver binding for the Bee harness.

This child component provides declarative launch generation, stream-json protocol normalization, configuration delivery, and native terminal interactive profiles for `agy`.

## Responsibility and Capabilities

| Component | Role |
|---|---|
| `bee.driver.agy:prepare` | Builds initial declarative launch specifications for `session`, `batch`, and `window` modes; expresses host-policy options without hardcoding a model |
| `bee.driver.agy:dispatch` | Builds resumed launch specifications requiring an existing `resume_ref` (`--conversation`) |
| `bee.driver.agy:normalize` | Structurally validates bounded incoming state, including every terminal answer, resume reference, usage counter/cost and fault field; pins conversation identity on init; refuses conflicting envelope/body or later conversation IDs; bounds each delta and the retained answer; normalizes wire envelopes into typed thread observations |
| `bee.driver.agy:configure` | Validates configuration requests; generates `.gemini/config/mcp_config.json` for gateway tools; refuses unsupported provider configuration and gateway HTTP hooks |

## Status and Gates

In accordance with Bee foundation conventions, unproven capabilities are strictly labeled:
- `M.AGY_AUTHENTICATION = "unproven"`: Headless authentication requires an existing user profile under `HOME`; `GEMINI_API_KEY` alone is not an account session and disables hooks. No automated credentials are admitted.
- `M.AGY_HOOKS = "unproven"`: Agy supports only local command hooks, not gateway HTTP hooks. Gateway HTTP hook requests are rejected, and unsupported hook capability claims are excluded from the profile.
- `M.AGY_MCP = "unproven"`: MCP configuration is generated as a private-home file (`.gemini/config/mcp_config.json`) supporting stdio and HTTP gateway tools with environment expansion `${GATEWAY_TOKEN}`, verified via `agy mcp help` and isolated fixture config. Live in-harness MCP operation is not yet verified through automated gates.

The normalizer treats the nested `result` object and its status as the terminal
boundary. A successful result must carry response text and a valid usage object
when usage is present; malformed usage, response, identity or status values fail
the turn. A single response delta is capped at the thread record bound before
observation emission, and retained answer text is capped at the same bound.

## Profiles

1. **`session` (default)**:
   - Mode: `session`, protocol: `stream-json`, revision: `agy-stream-json-1`
   - Stdin user turn encoded via canonical JSON; `readiness = "protocol:init"`
   - Per-process resume using `--conversation <uuid>`
   - MCP client transports: `stdio`, `streamable_http` (unsupported `sse` and `ws` excluded; hooks excluded)
2. **`batch`**:
   - Mode: `batch`, protocol: `stream-json`, revision: `agy-stream-json-1`
   - Same structured turn format as session
3. **`window`**:
   - Mode: `window`, protocol: `pty`, revision: `native-window-1`
   - Direct interactive TUI session with `readiness = "terminal:attached"`
   - Prompts passed via `--prompt-interactive <brief>`; empty prompt opens the native UI
   - Resuming passes `--conversation <uuid>`

## Integration Seam

This child component owns only `src/driver/agy` and `tests/lua/driver/agy`. The shared build manifest `build/modules.json` does not yet list `bee.driver.agy` under the `bee/driver` module namespaces; registering that entry and adding activation declarations in the harness catalog are shared repository integration seams reserved for parent review.
