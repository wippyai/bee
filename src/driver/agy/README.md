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

The default window keeps the OS user's HOME, so Agy sees its normal settings,
login, conversations and global customizations. Bee writes its scoped MCP,
hooks and profile instructions under the retained session's `.agents`
customization root and passes that root through Agy's supported `--add-dir`.
It never edits the user's `.gemini` tree or the project. Gateway configuration
generates `.agents/mcp_config.json` with a scoped Bee URL and an empty credential
field in its measured template. Native placement fills the declared JSON field
with the admitted token when writing the retained file; Agy does not interpolate
token environment references. The window profile also renders command hooks for
`PreToolUse`, `PostToolUse` and `Stop` in `.agents/hooks.json`. The
host-selected Bee helper posts observations to the existing hook endpoint and
emits no permission decision. Missing helper selection, unsupported events and
provider configuration are refused. The component still declares its opaque
login format for private structured profiles. The default window needs no login
projection because it uses the host-authorized HOME directly.
The native executable fixture proves present/absent global login, an unchanged
global configuration tree, private retained-root containment and scoped MCP
requests from the generated configuration. The opt-in live acceptance starts
installed Agy 1.2.2 without a model prompt and observes it loading the added
hooks root before a prompt detach. A separate managed read task commits tool and Stop observations.
An actual managed MCP task also commits one bound-thread message when the two
fixture tools are explicitly allowed in its private permissions file. Production
retains the harness permission prompts; this is not automatic approval or cold
conversation recovery. The host selects the executable and
grants; the component declaration alone gives no execution authority.

Strict lint, all 886 unit cases, packaged native selection, installed-Agy startup
and loopback-only boot checks pass for this source. The current global Train A
binary does not include the host-HOME/additional-root change. Earlier hook and
managed-turn evidence remains recorded in
[the hook integration handoff](../../../docs/handoffs/AGY_HOOKS.md).
