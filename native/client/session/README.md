# Native client session

`Join(ctx, Config, stdin, stdout)` composes the existing SameAccount native mesh,
Hive desktop binding and physical presenter. It is gated by `meshclient` and
`physicalclient`; public launch does not call it yet. It creates no owner,
workspace database, transport implementation or registry deployment.

The host selects a protected discovery directory, an explicit control/observe
mode, and optionally an exact workspace/desktop pair. With no pair, precisely
one desktop must exist. Empty and ambiguous catalogs are errors; discovery order
never selects a workspace. Each call owns a fresh actor and one mount. Attachment requests
and input are never replayed. Supervisor discovery and catalog readiness share
a 15-second deadline. Only definite UNAVAILABLE catalog refusals trigger another
read, after 50 ms with a fresh key; all other failures return immediately. Cleanup requests supervisor detach within a bounded
context and keeps operation and cleanup failures visible.

The caller owns physical files and the signal context. Ctrl+] detaches locally;
applications remain owned by the remote runtime. Starting that owner and deciding
its lifetime are launcher responsibilities, not side effects of Join.

`make -C native client-session-check MESH_RUNTIME=/absolute/reviewed/runtime`
checks selection and validation plus race/vet. The stronger optional
`localowner.TestFreshClientDesktopComposition` proves a fresh second native client
presents the retained Terminal through an OS PTY, reads the earlier client's shell
variable, and detaches. It uses actual Bee modules and supervisor admission, not
fixture-issued viewport grants. See the localowner README for the command.

`Probe(ctx, directory)` shares authenticated supervisor/catalog readiness with
Join but creates no attachment. It is bounded to 15 seconds including transport
startup, and is used by explicit start when another runtime owns the state lock.
It does not select control, resize a viewport or claim delivery obligations.
