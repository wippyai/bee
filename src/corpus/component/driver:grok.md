# bee.driver.grok

Grok CLI profiles and a strict CLI descriptor (`bee.driver.grok.descriptor:cli`)
selecting the universal launch layer and the shared Grok streaming-json codec,
plus admitted configuration. The binding is `bee.driver.grok.binding:binding`.

The host supplies the executable environment and window policy. The component
declares no process authority, credential access or MCP permissions.

A private batch launch receives `.grok/auth.json` and uses the admitted
`.grok/config.toml` as a private composition base, imported to
`.grok/.bee-global-config.toml` without its `hooks` and `mcp_servers` tables.
`GROK_HOME` points into the private home, where placement creates the final
composed config. If Grok refreshes `auth.json`, only that login file is returned
through the credential broker after exit. The base and generated configuration
are not written back.

Login evidence accepts the cached `.grok/auth.json` file or the declared
API-key environment names (`XAI_API_KEY`, `GROK_CODE_XAI_API_KEY`).
Configuration existence alone is not login evidence. Launch policies select the
`grok_login` credential projection.
