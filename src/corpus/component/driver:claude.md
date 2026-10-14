# bee.driver.claude

Claude Code profiles and a strict CLI descriptor (`bee.driver.claude.descriptor:cli`)
selecting the universal launch layer and the shared Claude stream-json codec,
plus admitted configuration. The binding is `bee.driver.claude.binding:binding`.

The host supplies the executable and API-key environment and each route's
policy. The component declares no process authority, credential access or MCP
permissions.

The private batch route receives `.claude/.credentials.json` and the optional
`.claude/settings.json` from the machine home and points `CLAUDE_CONFIG_DIR`
into the attempt home. Claude may refresh its own `.credentials.json`;
placement returns only that login file through the credential broker after exit.
Configuration is not written back. The credential format creates `.claude.json`
with the onboarding-complete marker alongside the login. Window launches keep
the machine home and the login hint.

When Bee gateway tools are selected, the launch passes them to
`--allowedTools` with the `mcp__bee__` prefix and always includes `session`.
The gateway still checks session operations against the admitted binding.

Edit-capable Claude profiles declare the `claude_add_dir` Git writable-roots
adapter. For a writable workdir inside a repository or worktree, placement adds
the exact Git directory and common directory with `--add-dir`, after checking
both against the host-admitted write roots.

Structured session and batch profiles declare the command, HTTP and MCP hook
transports and the supported events. The host-selected hook allowlist is
intersected with those capabilities before gateway admission. The boolean
options `permission_exchange` and `control_enabled` apply to structured turns
only; `control_enabled` keeps stream-json input open.
