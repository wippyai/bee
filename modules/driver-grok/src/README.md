# Bee Grok driver

Install `bee/driver-grok` with `bee/driver` and `bee/threads`. It supplies Grok
CLI profiles and a strict CLI descriptor selecting the universal launch layer
and shared Grok streaming-json codec, plus admitted configuration.

The host supplies the executable environment and window policy. The component
declares no process authority, credential access, or MCP permissions.

The private batch route receives `.grok/auth.json` and uses the admitted
`.grok/config.toml` as a private composition base. `GROK_HOME` points into the
attempt home, where placement creates the final composed config. If Grok
refreshes `auth.json`, only that login file is returned through the credential
broker after exit. The base and generated configuration are not written back.
