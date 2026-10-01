# Bee Codex driver

Install bee/driver-codex with bee/driver and bee/threads. It supplies Codex CLI
profiles and a strict CLI descriptor selecting the universal launch layer and
shared Codex JSONL codec, plus the configuration renderer.

The host supplies a read-only executable environment and a launch policy for
each route. Installing this component does not activate Codex, expose a user
home, copy credentials, or grant MCP tools.

## Named configuration profile

When a host policy declares the bounded text option config_profile, this
component validates the value as a plain Codex profile name and invokes
`codex --profile <name>`. Codex loads `$CODEX_HOME/<name>.config.toml` on top
of its normal configuration. Private batch routes receive the one selected
named profile alongside `~/.codex/auth.json` and `~/.codex/config.toml`; the
driver declares that exact file and the credential broker reads only its
host-admitted path. Placement points `CODEX_HOME` into the attempt home.
Window routes keep using the machine's Codex home directly.

## Provider configuration

The normal window uses the user's existing Codex login. Private batch routes
receive the admitted login, base config and selected named profile. The
component renders only that provider's approved model, reasoning effort,
developer instructions, scoped MCP connection and hook configuration. Codex
may refresh `auth.json`; placement returns only that login file through the
credential broker after exit. Codex reads batch briefs from stdin, so those
launches declare end-of-file input and placement closes stdin after writing the
brief.

The confined `workspace-write` profiles declare Codex's Git writable-roots
adapter. When the granted workdir is a repository or worktree, native placement
adds the exact `.git` directory and, for a worktree, its shared Git common
directory through `sandbox_workspace_write.writable_roots`. Placement adds
these roots only when both are inside a host-admitted write root.

## Profile prompt append

`provider.system_prompt_append` becomes additive `developer_instructions` in the
private `.codex/config.toml`. A host provider projection appends it to host guidance.
Ordinary user configuration is copied by the credential owner into the private
`.codex/.bee-user-config.toml` and the existing TOML composition inserts or appends
only the guidance leaf; other settings and named profiles remain intact. The
original host files are not changed. `model_instructions_file` is not selected
because it replaces Codex's built-in instructions, according to the
[official config reference](https://developers.openai.com/codex/config-reference).
