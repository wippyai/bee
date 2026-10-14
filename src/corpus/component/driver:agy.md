# bee.driver.agy

Agy profiles and a strict CLI descriptor (`bee.driver.agy.descriptor:cli`)
selecting the universal launch layer and the shared Agy stream-json codec, plus
admitted configuration. The binding is `bee.driver.agy.binding:binding`.

The host supplies the executable environment and each route's policy. The
component declares no process authority, credential access or MCP permissions.

Edit-capable Agy profiles declare the `agy_add_dir` Git writable-roots adapter.
For a writable workdir inside a repository or worktree, placement adds the exact
Git directory and common directory with `--add-dir`, after checking both against
the host-admitted write roots.

Private batch routes receive `.gemini/antigravity-cli/antigravity-oauth-token`
and, when present, `.gemini/antigravity-cli/cache/onboarding.json` from the
machine home, under a private attempt `HOME`. Placement returns only the OAuth
token file when Agy refreshes it; onboarding is not written back.
