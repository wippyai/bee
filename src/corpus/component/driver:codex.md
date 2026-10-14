# bee.driver.codex

Codex CLI profiles and a strict CLI descriptor (`bee.driver.codex.descriptor:cli`)
selecting the universal launch layer and the shared Codex JSONL codec, plus the
configuration renderer. The binding is `bee.driver.codex.binding:binding`.

The host supplies a read-only executable environment and a launch policy for
each route. Installing the component does not activate Codex, expose a user
home, copy credentials or grant MCP tools.

## Named configuration profile

When a host policy declares the bounded text option `config_profile`, the
driver validates the value as a plain Codex profile name and invokes
`codex --profile <name>`. Codex loads `$CODEX_HOME/<name>.config.toml` on top of
its normal configuration. Private batch routes receive the one selected named
profile alongside `.codex/auth.json` and `.codex/config.toml`; the driver
declares that exact file and the credential broker reads only its
host-admitted path. Placement points `CODEX_HOME` into the attempt home. Window
routes use the machine's Codex home directly.

## Provider configuration

The normal window uses the user's existing Codex login. Private batch routes
receive the admitted login, base config and selected named profile. The
component renders only the approved model, reasoning effort, developer
instructions, scoped MCP connection and hook configuration. Codex may refresh
`auth.json`; placement returns only that login file through the credential
broker after exit. Batch launches run `codex exec --json` with the brief on
stdin and declare end-of-file input.

The confined `workspace-write` profiles declare the `codex_workspace_write` Git
writable-roots adapter. When the granted workdir is a repository or worktree,
native placement adds the exact `.git` directory and, for a worktree, its shared
Git common directory through `sandbox_workspace_write.writable_roots`, only when
both are inside a host-admitted write root.

## Profile prompt append

`provider.system_prompt_append` becomes additive `developer_instructions` in the
private `.codex/config.toml`. The credential owner copies ordinary user
configuration into the private `.codex/.bee-user-config.toml`, and the TOML
composition inserts or appends only the guidance leaf; other settings and
named profiles remain intact. The original host files are not changed.
