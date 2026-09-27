# Bee Muse driver

Install `bee/driver-muse` with `bee/driver` and `bee/threads`. It supplies Muse
profiles, stream normalization, launch declarations, and admitted configuration
for the shared driver contract.

The host supplies the executable environment and each route's policy. The
component declares no process authority, credential access, or MCP permissions.

The private batch route receives `.config/muse/auth.json` and uses an admitted
`.config/muse/settings.json` as a private composition base under its attempt
`HOME`. Placement composes the final settings file there. A refreshed `auth.json`
may be returned through the credential broker after exit; configuration is not
written back.
