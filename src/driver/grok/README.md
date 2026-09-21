# bee.driver.grok

Grok is a separate harness component assembled as `bee/driver-grok`. It implements
`bee.driver:driver`: prepare or resume a launch, render admitted configuration,
and normalize protocol records. It owns no executor, credential store or service.
The host selects activation, executable, profile and permissions. Bundling the
component does not publish it independently to Hub or activate a launch profile.

The driver targets Grok CLI 1.0.30. Its `session` and `batch` profiles use
`--output-format streaming-json`; session continuation supplies `-r` with the
recorded conversation reference. The `window` profile runs the normal Grok TUI
through the existing terminal placement. Structured turns admit bounded
`max_turns`, model, reasoning effort and Grok's native permission modes. Window
mode preserves interactive permission defaults and refuses `max_turns`.
Prompts and resume references cannot become command-line options.

The default window requests the optional `grok_login` credential. Its component
declares `.grok/auth.json`; the host separately admits that exact machine file
and may admit `.grok/config.toml` as setup. The broker snapshots that one ordinary
configuration file into retained private `.grok/.bee-global-config.toml` once,
including when login is absent. At materialization, placement parses that
snapshot and structurally inserts only Bee's `mcp_servers.bee` subtree into the
private `.grok/config.toml`. An existing subtree with that name refuses before
the child starts. Bee adds `MCPTool(bee__*)` through Grok's `--allow` argument;
it does not replace the user's permission configuration. The user's global tree
remains unchanged. Other machine files, trusted folders, sessions and MCP
credentials are not copied. A missing login leaves normal Grok sign-in available
in the private retained home.

The normalizer retains the first valid session identity, validates persisted
state and bounds accumulated answers to 12,288 bytes. Larger answers remain in
their thread observations; the terminal summary omits the accumulated answer.
Only explicit completed/failed tool statuses produce results. The end envelope
reports completion; missing or unknown stop reasons and EOF remain uncertain.
A process exit alone never establishes success.

Gateway configuration projects `.grok/config.toml` with a scoped Bee MCP URL and
an environment-token reference. It accepts no external provider configuration.
The window profile declares SessionStart, UserPromptSubmit, PreToolUse,
PostToolUse and Stop command hooks. The host separately admits these events and
selects the existing Bee `hook-post` executable. Generated `.grok/hooks/bee.json`
uses the separate hook credential environment; hook-only configuration creates
no MCP server. The helper reports observations and emits no permission decisions.

The gateway accepts both camelCase and snake_case hook fields, rejects
conflicting aliases, preserves bounded session/turn/tool claims and hashes
content instead of retaining it. Provider model turns and cold window recovery
remain outside this driver contract.
