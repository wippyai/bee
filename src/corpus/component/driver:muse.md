# bee.driver.muse

Muse profiles and a strict CLI descriptor (`bee.driver.muse.descriptor:cli`)
selecting the universal launch layer and the shared Muse record-JSONL codec,
plus admitted configuration. The binding is `bee.driver.muse.binding:binding`.

The host supplies the executable environment and each route's policy. The
component declares no process authority, credential access or MCP permissions.

The private batch route receives `.config/muse/auth.json` and imports an
admitted `.config/muse/settings.json` as the private composition base
(`.config/muse/.bee-global-settings.json`) under its attempt `HOME`. Placement
composes the final settings file there. A refreshed `auth.json` may be returned
through the credential broker after exit; configuration is not written back.
