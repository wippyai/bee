# Native client checkpoint

This checkpoint preserves the Bee-owned native mesh, Hive binding and physical
presentation components plus their protected local rendezvous dependencies.
It is not registered in the public launcher and does not enable Hive. Production
Lua, root build configuration and runtime sources are unchanged from its parent.

Run `make -C native client-check MESH_RUNTIME=/path/to/compatible/runtime`.
The explicit runtime checkout must supply native TLS and surface transport APIs;
the module's old default runtime pin is not sufficient for these gated packages.
The temporary module replacement does not alter go.mod or go.sum.

The binding uses actual sender identity and the protected supervisor lookup.
It has no Lua/native ingress dependency or connection credential. Actor lifetime
cancellation does not prove remote revocation. Local rendezvous enrollment applies
only to the same OS account; remote invitation redemption remains unimplemented.

Unit, race and native two-process viewport checks are component evidence. The
real Bee supervisor fixture remains blocked with the available owner candidate:
its non-TLS handshake is rejected by the TLS client. Runtime #712 supplies TLS
boot wiring; #706 supplies surface transport and #718 the typed Lua listener.
They remain upstream integration requirements. Public auto-attachment, live
supervisor enrollment and remote actor-loss cleanup still require acceptance.

The fixture executable is for disposable pre-enrolled test environments only.
`BEE_NATIVE_DESKTOP_DIAGNOSTICS=1` enables its native transport logs.
