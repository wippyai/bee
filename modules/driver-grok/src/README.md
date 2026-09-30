# Bee Grok driver

Install `bee/driver-grok` with `bee/driver` and `bee/threads`. It supplies Grok
CLI profiles and a strict CLI descriptor selecting the universal launch layer
and shared Grok streaming-json codec, plus admitted configuration.

The host supplies the executable environment and window policy. The component
declares no process authority, credential access, or MCP permissions.

A private batch launch without a retained session receives `.grok/auth.json`
and uses the admitted `.grok/config.toml` as a private composition base.
`GROK_HOME` points into the attempt home, where placement creates the final
composed config. If Grok
refreshes `auth.json`, only that login file is returned through the credential
broker after exit. The base and generated configuration are not written back.

Login evidence accepts the cached auth file, model-provider settings in
`.grok/config.toml`, or the declared API-key environment names. The existing
broker projection carries the admitted config even when the optional auth file
is absent. The default window keeps its private HOME and host-selected
`grok_login` projection. When a launch selects a retained session home, both
`HOME` and `GROK_HOME` use that home across turns. The first projection seeds
login and configuration; matching resumes preserve the session's login and
conversation files. Config bytes remain private to the broker and CLI.
