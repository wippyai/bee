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

Protocol handling follows `init`, `step_update` and nested `result` frames.
State, usage and fault fields are decoded at the boundary; conversation
identity changes cannot replace the selected session. Missing terminal results
remain uncertain.

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
The host selects the executable and grants; the component declaration alone
gives no execution authority. Placement and the credential broker own retained
session state and login materialization. Interactive TUI recovery and arbitrary
orphan-tree recovery are outside this driver contract.
