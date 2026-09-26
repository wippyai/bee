# Bee OpenCode driver

Install bee/driver-opencode with bee/driver and bee/threads. It supplies
OpenCode profiles, stream normalization, launch declarations, and the
configuration renderer for the shared driver contract.

The host supplies a read-only executable environment and a launch policy for
each route. Installing this component does not activate OpenCode, expose a
user home, copy credentials, or grant MCP tools.

## User-configured models

OpenCode takes no model, provider or endpoint profiles from Bee. The user
selects models, providers and permissions in their own OpenCode home, and the
window and batch routes inherit that home. A configuration request naming a
provider is refused.

The normal window uses the user's existing OpenCode login (`opencode auth
login` writes `~/.local/share/opencode/auth.json`). Bee checks that file's
existence only and never reads its contents.

## Launch

The window runs the interactive TUI with no positional prompt (a positional
argument would select a project directory); a brief travels in the `--prompt`
option, and `--session` resumes a session. The batch route runs `opencode run
--format json`, which streams newline-delimited JSON events for one
non-interactive turn; the brief travels as the run message after `--`, and
`--session` resumes. OpenCode never reads a prompt from stdin, so batch
launches declare no stdin: an inbox item arrives as a new admitted process on
the resumed session while stdin stays closed.

## Gateway MCP

A host-selected gateway renders into `.config/opencode/opencode.json` as the
single scoped `bee` remote entry, composed into the user's own configuration
without replacing unrelated keys. Credentials stay with the host credential
path and reach the file through secret fields.

## Hooks

OpenCode offers no hook transport: its plugin events are provider-owned
JavaScript, not Bee's admitted hook handlers. Both profiles declare no hook
transport, and any requested gateway hook event is refused at decode time
rather than silently dropped.
