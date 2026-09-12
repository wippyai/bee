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
an environment-token reference. It accepts no external provider configuration
or hooks. The installed CLI advertises stdio, Streamable HTTP and SSE MCP
transports. Token interpolation and an authenticated managed MCP turn remain
unverified; the installed Grok CLI was logged out during acceptance.

`tests/lua/driver/grok` covers launch arguments, configuration bounds, malformed
state, session changes, answer bounds and terminal/tool outcomes. These fixtures
remain outside production packs. Run the repository's `make lint` and `make test`
with the selected `WIPPY` runtime.
