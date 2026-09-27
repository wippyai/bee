# Bee Agy driver

Install `bee/driver-agy` with `bee/driver` and `bee/threads`. It supplies Agy
profiles, stream normalization, launch declarations, and admitted configuration
for the shared driver contract.

The host supplies the executable environment and each route's policy. The
component declares no process authority, credential access, or MCP permissions.

Edit-capable Agy profiles declare the Git writable-roots adapter. For a
writable workdir inside a repository or worktree, placement adds the exact Git
directory and common directory with `--add-dir`, after checking both against
the host-admitted write roots.

Private batch routes receive `~/.gemini/antigravity-cli/antigravity-oauth-token`
and, when present, `~/.gemini/antigravity-cli/cache/onboarding.json` from the
machine home. Agy runs with the private attempt `HOME`. Placement returns only
the OAuth token file if Agy refreshes it; onboarding and other home files are
not written back.
