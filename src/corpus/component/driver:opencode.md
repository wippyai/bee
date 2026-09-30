# Bee OpenCode driver

Install bee/driver-opencode with bee/driver and bee/threads. It supplies
OpenCode profiles and a strict CLI descriptor selecting the universal launch
layer and shared OpenCode JSON event codec, plus the configuration renderer.

The host supplies a read-only executable environment and a launch policy for
each route. Installing this component does not activate OpenCode, expose a
user home, copy credentials, or grant MCP tools.

## User-configured models

OpenCode takes no model, provider or endpoint profiles from Bee. The user
selects models, providers and permissions in their own OpenCode home. A
configuration request naming a provider is refused. The window uses the
machine home. A private batch route receives only the admitted auth file and
global config base, with its XDG config and data roots pointed into the attempt
home.

The normal window uses the user's existing OpenCode login (`opencode auth
login` writes `~/.local/share/opencode/auth.json`). Readiness also accepts global
`opencode.json` or `opencode.jsonc` provider configuration and declared
provider-key environment names, checking presence only. Config can reference
provider key files; the authorized window HOME lets OpenCode resolve those
references itself. A private batch route receives the admitted login and
global config through the credential broker; placement reads only those
declared files and returns only the login file after a token refresh.

The batch route may refresh `auth.json`; placement returns only that login file
through the credential broker after exit. Configuration and unrelated home
files are not written back.

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
single scoped `bee` remote entry, composed into the admitted provider config
without replacing unrelated keys. Gateway credentials reach that file through
secret fields.

## Hooks

OpenCode offers no hook transport: its plugin events are provider-owned
JavaScript, not Bee's admitted hook handlers. Both profiles declare no hook
transport, and any requested gateway hook event is refused at decode time
rather than silently dropped.

Headless first and resumed turns close an explicitly empty stdin after delivering
the argv brief. OpenCode waits for pipe EOF before starting `run`; the universal
driver emits the same declarative EOF delivery on native and Docker placement.
