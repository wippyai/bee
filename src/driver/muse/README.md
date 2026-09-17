# bee.driver.muse

The Muse harness component implements the shared Bee driver contract:
prepare and resume a launch, normalize protocol records, and render admitted
configuration. It contains no execution service or credential store. The host
selects activation, profiles, executable and permissions; this package grants
none of them. Placement owns execution and the credential broker owns login
materialization.

It is assembled as `bee/driver-muse`, separately from the shared
`bee/driver` contract and other harness bindings. It requires that contract,
its kit and thread-record decoders in the host composition. Native bundle
assembly does not establish independent Hub publication. See the shared
driver documentation for implemented authentication, MCP and recovery gates.

## Verified against muse 1.3.0

`muse exec` offers no argv delivery for MCP servers, hooks or instructions
(the full `muse exec --help` carries no `--mcp-config`, `--settings` or
`--append-system-prompt` flag), so configure renders one protected
`muse/settings.json` file under the private `XDG_CONFIG_HOME`, the way Codex
uses protected files. Startup validation and echo-provider runs verify the
file location, the required `schema_version`, the matcher-group hook shape,
command-hook execution with the event JSON on stdin, and every listed hook
event. The gateway calls back through the host-selected hook command; token
bytes never enter the file. MCP tool invocation through the rendered server
entry is accepted at startup but unproven without a Meta provider, and
`--session-id` pins the session identity, and a two-call real-provider probe
(memorize a random code, then recall it under the same session id) shows the
follow-up answers from prior context, so dispatch resumes by starting a new
process on that session. The prompt travels as a
positional argument behind `--` because `exec` reads no prompt from stdin.
Effort admits the same range as the other drivers, and batch turns default
to `--approval-mode on-request` unless the host selects `never`.
