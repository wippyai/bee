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

The B1.1 acceptance launches real Grok 1.0.30 and checks `inspect --json` for the
preserved user settings, existing user MCP, Bee MCP, user hooks and Bee hooks.
It also requires an authenticated SessionStart through the helper without a
user prompt or model turn. The current standalone composition candidate passes
this acceptance; the runtime-module review and complete release gate remain
pending.
Its payload carries both camelCase and snake_case aliases. The gateway accepts
matching aliases, rejects conflicts, preserves bounded session/turn/tool claims,
and hashes content instead of retaining it. Unit checks cover the captured
SessionStart shape and documented tool shape. The assembled executable's
Grok fixture now passes picker launch, present/absent machine login, scoped MCP,
committed PreToolUse/Stop delivery and the resulting "Using tool" window title.
This fixture does not prove real Grok model turns or cold window recovery.
Evidence: `bee-evidence/0912/grok-session-hook-live.log` and
`agent-login-hooks-grok-title.log`. Global binary `c8537ef7` includes this integration.

The installed CLI advertises stdio, Streamable HTTP and SSE MCP
transports. A September 13 loopback probe of the actual `grok mcp doctor`
confirmed `${BEE_TEST_TOKEN}` expansion: initialize and tools/list requests
carried the expanded dummy credential. The diagnostic returned exit 1 against
the minimal server, so this is only header-behavior evidence, not a healthy-server
or completed agent-turn proof. An authenticated managed MCP turn remains
unverified; the installed Grok CLI was logged out during earlier acceptance.
Evidence: `bee-evidence/0912/grok-mcp-header-expansion.log`.

`tests/lua/driver/grok` covers launch arguments, configuration bounds, malformed
state, session changes, answer bounds and terminal/tool outcomes. These fixtures
remain outside production packs. Run the repository's `make lint` and `make test`
with the selected `WIPPY` runtime.
