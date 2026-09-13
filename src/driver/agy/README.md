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
Bee URL and an empty credential field in its measured template. Native placement
fills the declared JSON field with the admitted token when writing the private
file; Agy does not interpolate token environment references. The window profile also renders command
hooks for `PreToolUse`, `PostToolUse` and `Stop` in its private hooks.json. The
host-selected Bee helper posts observations to the existing hook endpoint and
emits no permission decision. Missing helper selection, unsupported events and
provider configuration are refused. The component declares its opaque login file at
`.gemini/antigravity-cli/antigravity-oauth-token`. The default host admits only
that machine file for an optional private copy, preserving private refreshes;
it does not link the machine directory or copy conversations and settings.
The native executable fixture proves present/absent login projection and scoped
MCP requests from the generated configuration. A separate actual Agy 1.2.2 managed read task commits tool and Stop observations.
An actual managed MCP task also commits one bound-thread message when the two
fixture tools are explicitly allowed in its private permissions file. Production
retains the harness permission prompts; this is not automatic approval or cold
conversation recovery. The host selects the executable and
grants; the component declaration alone gives no execution authority.

Packaged native acceptance, live command-hook delivery and loopback-only boot
checks pass for the corrected candidate. Installation remains gated by the full
source/pack regression; see
[the hook integration evidence](../../../docs/handoffs/AGY_HOOKS.md).
