# bee.driver.grok

Grok is a separate harness component assembled as `bee/driver-grok`. It implements
`bee.driver:driver`: prepare or resume a launch, render admitted configuration,
and normalize protocol records. It owns no executor, credential store or service.
The host selects activation, executable, profile and permissions. Bundling the
component does not publish it independently to Hub or activate a launch profile.

The driver targets Grok CLI 1.0.24. Its `session` and `batch` profiles use
`--output-format streaming-json`; session continuation supplies `-r` with the
recorded conversation reference. The `window` profile runs the normal Grok TUI
through the existing terminal placement. Structured turns admit bounded
`max_turns`, model, reasoning effort and Grok's native permission modes. Window
mode preserves interactive permission defaults and refuses `max_turns`.
Prompts and resume references cannot become command-line options.

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

A real Grok 1.0.24 TUI startup delivered an authenticated SessionStart through
that helper to a private loopback fixture, with no user prompt or model turn.
Its payload carries both camelCase and snake_case aliases. The gateway accepts
matching aliases, rejects conflicts, preserves bounded session/turn/tool claims,
and hashes content instead of retaining it. Unit checks cover the captured
SessionStart shape and documented tool shape. Actual managed Grok tool/Stop
delivery, title updates and cold window recovery remain unverified.
Evidence: `bee-evidence/0912/grok-session-hook-live.log` and
`grok-window-hooks-focused.log`. This source is not installed globally.

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
