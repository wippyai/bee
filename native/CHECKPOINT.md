# Native client checkpoint

This branch preserves Bee’s native enrollment, owner service composition and
foreground physical client. The host selects permissions, and the retained
owner keeps applications alive across client detach. It uses native mesh;
there is no additional transport or runtime ingress API.

The native launcher supports automatic cold start, authenticated reuse and
concurrent explicit starts. The single `desktop.Component` factory composes
owner, Hive service, client launcher and I/O. This is a native-only checkpoint;
the public release manifest and global binary have not been switched to it.

Run `make -C native local-owner-check client-session-check
MESH_RUNTIME=/absolute/reviewed/runtime` as one command. The runtime needs launch
hooks, native viewport transport, dynamic peer-key resolution and TLS boot APIs.
For the actual-source proof also set `BEE_OWNER_TEST_WIPPY` to the compatible
pack toolchain and `BEE_OWNER_TEST_SOURCE` to a current absolute Bee checkout.
That source supplies `src/`, `build/modules.json` and `wippy.build.json`, including
production activation, headless wait command and supervisor policies. The test
skips without its explicit toolchain. An ioevents-only host cannot load activation.

The real-source composition test passes under race checking: empty cold desktop,
Terminal opened from Start, authenticated reuse, signal exit with terminal
restoration, fresh retained-shell rejoin, and concurrent starts leaving one owner.
Signal interruption may surface a typed input/resize delivery error; acceptance
allows the specific mount-expired delivery error but still requires restoration
and retained rejoin. Production preserves that uncertainty and never replays input.
Physical-client cancellation and delivery-error tests also pass under race checking.

This is not a combined-runtime release, overlay-upgrade proof, LAN deployment,
or installed public-launch acceptance. Runtime 944736c999 supplies the launcher
APIs but lacks clipboard support; the selection candidate supplies clipboard but
lacks those launcher APIs. A reviewed combination and full Bee checks are still
required before replacing the installed global Bee. Remote physical clipboard
routing is unimplemented. Windows launch flags remain unverified.

The native client now requests selection text through `bee.desktop:copy` for
explicit Ctrl+C. The current external Bee source must include that operation,
the retained supervisor's ordered `bee.copy` input marker and presenter result
path. The source is not part of this native-only checkpoint. The unused inbox
push experiment was removed; copy uses the existing serialized Hive call/reply.

The native binding fences reply session/expiry and plain-text bounds. Physical
output rechecks the native mount, serializes clipboard/frame writes, consumes
copy key releases, preserves ordinary Ctrl+C and refuses unknown outcomes without
replay. Definite selection refusals leave the client running. Isolated physical
copy tests pass against the clipboard-capable runtime; binding/session tests and
actual-source ordinary-interrupt/cold/rejoin composition pass against the launcher
runtime (58.096s for composition). Lint and pack architecture pass on current Bee
source, with 517 entries. Full Lua boot remains blocked by the old toolchain's
missing activation listener. Full selected-window native-client acceptance and
an installed global build remain unproven until the runtime APIs are combined.

The physical cancellation regression now proves a cancellation observed during
native grant checking cannot start a later clipboard write. Physical race/vet
passes1.039s. The expanded actual-source composition passes60.585s: a second
native client observes but cannot copy; substituted and detached sessions are
refused; the original controller continues using its shell. Independent observer
selection and combined-runtime release acceptance remain unproved.

`local-owner-selection-check` is the explicit full selected-window release gate.
Set `BEE_OWNER_TEST_WIPPY`, `BEE_OWNER_TEST_SOURCE` and `MESH_RUNTIME` as above.
It uses a native VT emulator to locate actual rendered Terminal text, opens
Select text, drags, sends Ctrl+C immediately after release, checks one exact
OSC52 payload, then reconnects and rejects replay. It never injects selected
text or substitutes a local-only display.

The initial full-path run reached selection but timed out waiting for the owner.
A compiled-module preflight now reports the missing `tty.text.plain` and physical
`Clipboard` APIs directly. This test is red on runtime944736c999; the complete
selected-window flow remains unverified. Default `local-owner-check` includes
this gate when its explicit toolchain is provided; the narrower
`LOCAL_OWNER_TEST_RUN=TestFreshClientDesktopComposition` remains the ordinary
owner/client proof and must not be described as selected-window acceptance.
