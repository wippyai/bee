# bee.driver.agy

The Antigravity CLI driver is assembled as `bee/driver-agy`, separate from the
shared `bee/driver` contract, kit and transport. It returns launch specifications,
normalizes protocol records and renders admitted configuration. Placement owns
execution; the host selects profiles, executable and permissions.

The `session` and `batch` profiles use stream-json print mode, with one canonical
user envelope on stdin. The `window` profile launches the ordinary Agy TUI.
Continuation uses the recorded `--conversation` reference. Host options use
Agy's native `mode`, model and effort vocabulary. Foreign `permission_mode` and
`max_turns` options are refused; only the explicit host option
`dangerously_skip_permissions` can select that CLI bypass.

Protocol handling follows captured `init`, `step_update` and nested `result`
frames. State, usage and fault fields are decoded at the boundary; conversation
identity changes cannot replace the pinned session. Missing terminal results
remain uncertain. Tests use captured protocol fixtures and malformed records;
they remain outside the production pack.

Gateway configuration generates `.gemini/config/mcp_config.json` with a scoped
Bee URL and environment-token reference. Unsupported provider configuration and
HTTP hooks are refused. Automatic user-login reuse and a live managed MCP turn
remain unverified. Driver activation does not supply a production launch profile,
credentials or execution permissions.
