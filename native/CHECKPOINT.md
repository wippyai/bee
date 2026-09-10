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

The binding now exclusively reads the native inbox and separates bounded Hive
reply and clipboard queues. Overflow retires physical presentation; close joins
the reader. Routing grants no clipboard authority and performs no copy yet.
Hive/session race and vet checks pass; full real-source composition passes
55.502s, preserving cold start, Start/Terminal, signal restore and retained rejoin.
