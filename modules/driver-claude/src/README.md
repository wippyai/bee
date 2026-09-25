# Bee Claude driver

Install `bee/driver-claude` with `bee/driver` and `bee/threads`. It supplies
Claude Code profiles, stream normalization, launch declarations, and admitted
configuration for the shared driver contract.

The host supplies the executable/API-key environment and each route's policy.
The component declares no process authority, credential access, or MCP
permissions.
When Bee gateway tools are selected, the launch allows Claude Code's reserved
`mcp__bee__session` tool in `dontAsk` mode alongside those tools. The gateway
still checks session operations against the admitted binding. Gateway-only
authoring does not enable Claude's local `Edit` or `Write` filesystem tools.

For a fixture-enabled structured controller, `control_enabled` starts Claude
with stream-json input and keeps stdin open after the initial brief. The
carrier may then send an identified inbox item as a new user turn. The shipped
production host policy does not enable this route; a host enables it with a
`push_acceptance` naming the measured executable's acceptance record.
