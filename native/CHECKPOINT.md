# Native client checkpoint

This branch preserves Bee's native enrollment, owner service composition and
foreground physical client. It does not update the bundled application or enable
a public launcher. Ordinary automatic attachment and owner background startup
remain unfinished.

The host owns policy selection. The local-client policy checks native sender
identity and current enrollment inside a fork of the supervisor service frame.
The retained desktop owner keeps applications alive while clients detach.
No additional transport or runtime ingress API is introduced.

Run `make -C native local-owner-check client-session-check
MESH_RUNTIME=/absolute/reviewed/runtime` (as one command). The runtime needs the
launch hooks, native viewport transport, dynamic peer-key resolution and TLS
boot APIs; the release module pin alone does not supply this experimental set.

For the actual-source Terminal proof, additionally set `BEE_OWNER_TEST_WIPPY` to
the compatible typed-listener toolchain and `BEE_OWNER_TEST_SOURCE` to an absolute
current Bee checkout. That checkout supplies `src/`, `build/modules.json` and
`wippy.build.json`; this native-only branch does not contain the newer Lua
application composition. Without the explicit toolchain the test skips.

This checkpoint is not a release, an overlay upgrade proof, a LAN deployment,
or a public startup acceptance. The installed global binary is unchanged.
