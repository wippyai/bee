# Native client session

`JoinEnrolled(ctx, Config, node, key, stdin, stdout)` joins the project owner
with the identity the launch route enrolled, over loopback with the owner's mesh
credential (`Config.TLS`, the owner's `hive/mesh.pem` and
`hive/mesh-authorities.pem`), and presents a desktop through the Hive desktop
binding and physical presenter. `ListEnrolled` reads the owner's displays and
`Operate` runs one `bee hive` operation (`hive.Join`) without attaching a
desktop. They are gated by `meshclient` and `physicalclient`; the launch route
calls them after selecting or starting the project owner and enrolling the
client. They create no owner, workspace database, transport implementation or
registry deployment.

The host selects a protected discovery directory, an explicit control/observe
mode, and optionally an exact workspace/desktop pair. With no pair, one workspace
must exist. Control mode reuses the first display without a controller and
allocates a fresh durable identity only after definite `DESKTOP_CONTROLLED`
refusals. Observe mode uses the first listed display. An explicit pair is exact
and never allocates. Discovery order never selects a workspace. Each call owns a
fresh actor and one mount. Attachment requests
and input are never replayed. Supervisor discovery and catalog readiness share
a 15-second deadline. Only definite UNAVAILABLE catalog refusals trigger another
read, after 50 ms with a fresh key; all other failures return immediately. Cleanup requests supervisor detach within a bounded
context and keeps operation and cleanup failures visible.

The caller owns physical files and the signal context. Ctrl+] detaches locally;
applications remain owned by the remote runtime. Starting that owner and deciding
its lifetime are launcher responsibilities, not side effects of a session.

Waiting for an owner that is still preparing belongs to the launch route; it
only reads, creates no owner state and returns corruption and permission errors
at once. A session against an unpublished owner fails without creating state.

Foreground cancellation stops presentation first. The native connection and
admitted actor receive at most three seconds to finish explicit detach, restore
terminal settings and close normally. A stalled cleanup cannot keep transport
alive indefinitely.
If the transport grace has already expired, no further mutation is sent under
retired actor authority. Operation errors are retained.
