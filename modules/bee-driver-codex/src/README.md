# Bee Codex driver

Install `bee/driver-codex` with `bee/driver` and `bee/threads`. It supplies the
Codex CLI profiles, stream normalization, launch declarations, and configuration
renderer for the shared driver contract.

The host must supply a read-only executable environment and a launch policy for
each route. Installing this component does not activate Codex, expose a user
home, copy credentials, or grant MCP tools.

When a host allows a named Codex configuration profile, this component validates
its plain profile name before using Codex's `--profile` option. The selected
Codex home remains host-owned.
