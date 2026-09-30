# Bee Claude driver

Install `bee/driver-claude` with `bee/driver` and `bee/threads`. It supplies
Claude Code profiles and a strict CLI descriptor selecting the universal
launch layer and shared Claude stream-json codec, plus admitted configuration.

The host supplies the executable/API-key environment and each route's policy.
The component declares no process authority, credential access, or MCP
permissions.

The private batch route receives only `~/.claude/.credentials.json` and the
optional `~/.claude/settings.json` from the machine home. It points
`CLAUDE_CONFIG_DIR` into the attempt home. Claude may refresh its own
`.credentials.json`; placement returns only that login file through the
credential broker after exit. Configuration is not written back. The format
creates `.claude.json` with the onboarding-complete marker only when login bytes
are present. Window launches keep the machine home and the login hint.
When Bee gateway tools are selected, the launch allows Claude Code's reserved
`mcp__bee__session` tool in `dontAsk` mode alongside those tools. The gateway
still checks session operations against the admitted binding. Gateway-only
authoring does not enable Claude's local `Edit` or `Write` filesystem tools.

Edit-capable Claude profiles declare the Git writable-roots adapter. For a
writable workdir inside a repository or worktree, placement adds the exact Git
directory and common directory with `--add-dir`, after checking both against
the host-admitted write roots.

For a fixture-enabled structured controller, `control_enabled` starts Claude
with stream-json input and keeps stdin open after the initial brief. The
carrier may then send an identified inbox item as a new user turn. The shipped
production host policy does not enable this route; a host enables it with a
`push_acceptance` naming the measured executable's acceptance record.
