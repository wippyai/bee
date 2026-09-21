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
driver documentation for the common configuration, admission and recovery
contracts; Muse-specific acceptance status is listed below.

## Muse 1.3.0 integration status

`muse exec` offers no argv delivery for MCP servers, hooks or instructions
(the full `muse exec --help` carries no `--mcp-config`, `--settings` or
`--append-system-prompt` flag), so the driver returns a declarative JSON
composition for native placement. A managed Muse attempt uses a retained,
Bee-owned private `HOME` and deliberately leaves `XDG_CONFIG_HOME` unset;
Muse therefore reads the generated files from `$HOME/.config/muse`.

The host admits the user's Muse login and settings through the credential
setup path. The broker retains the source settings separately at
`.config/muse/.bee-global-settings.json`, and placement composes a fresh
`.config/muse/settings.json` for each attempt. That composition preserves the
provider, model and TUI settings, unrelated user MCP servers and existing
user hook groups. Bee inserts only its scoped `mcpServers.bee` entry and
appends its selected authenticated hook groups to the corresponding event
arrays. A pre-existing `mcpServers.bee` entry is refused; the gateway token is
materialized through the declared secret field and is not stored in the
settings source. Hook commands receive their event payload on stdin. The
separate hook credential is materialized in an attempt-qualified private JSON
file; the command contains only its absolute `@` file reference.

The batch route uses `--session-id` to continue a recorded Muse session. Its
prompt is a positional argument behind `--`, because `exec` reads no prompt
from stdin. Window resume cannot carry a new brief. The `msp-exec-1`
normalizer validates persisted state, pins the first valid session identity,
keeps protocol terminal outcomes authoritative and treats an early, unknown or
missing terminal as uncertain. Explicit `tool.call` and `tool.result` records
become the shared tool observations; lifecycle records without a stable call
identity remain extensions, including task failures. Effort admits the same
bounded range as the other drivers, and batch turns default to
`--approval-mode on-request` unless the host selects `never`.

Focused driver and composition tests cover the declarative boundaries. The
real `native-muse-recovery-live-check` now passes against `dist/bee-muse-v2`
with Muse 1.3.0. Its first turn calls the scoped `thread_read` tool, reads a
fixture file, and commits the selected SessionStart, UserPromptSubmit,
PreToolUse, PostToolUse and Stop hooks. After the Bee owner restarts, the
second launch resumes the exact provider session and recalls the same token
without tools or replaying the first prompt. The retained private `HOME`,
project, application, thread and conversation identity remain stable; the new
attempt, gateway binding and private hook-token path are fresh, and the
predecessor retires cleanly. The source auth, settings and project tree remain
unchanged. The wrapper leaves `XDG_CONFIG_HOME` unset and disables Muse's
experimental skill, goal and verification reminder agents only for this
exact-session test.
This proves the real managed path; the Muse candidate has not been installed
globally.
