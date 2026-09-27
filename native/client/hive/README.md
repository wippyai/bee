# Native Hive client binding

This `meshclient`-gated package binds the existing `bee.hive@1` protocol to one
native `mesh.Actor`. It creates no transport, principal, listener, database or
application permission. Native session presentation constructs it after joining
the enrolled owner's mesh.

`New(lifetime, actor, ownerNode)` receives a cancellable context owned by the
client actor's caller. One binding exclusively consumes that actor's control
inbox. Calls use bounded, cancellable serialization and a 30-second ceiling,
send once, authenticate the exact supervisor PID from native discovery, correlate
the reply and recheck that supervisor before accepting it. A replacement owner
retires the binding. The actor admits only packages whose runtime `IngressNode`
is the enrolled owner; each operation then checks its logical sender against the
discovered supervisor PID.

`UnknownOutcome` retains the operation and idempotency key when transport accepted
a request but no trustworthy completion arrived. It does not trigger replay.
`Reply.Done()` and `DesktopMount.Done()` describe the caller-owned actor lifetime,
not connection liveness, remote revocation or permission. The physical caller must
end that lifetime on actor/transport shutdown. Native viewport grants enforce
actual observation/input/resize rights at use time.

`NewDesktop` additionally binds owner execution and physical actor identity.
`List`, `Plan`, `Attach` and `Detach` validate workspace, desktop, recipient,
session, mode and expiry. `Plan` decodes the owner's tagged session decision;
allocation and attachment remain separate calls. `Current` reads the client's
current session on the display it presents; only its workspace may differ from
the mount the client held. A node's catalog can contain multiple workspaces.
Ordinary typed refusals remain distinct from uncertain mutations. No method
owns the terminal, starts a workspace or retries a mutation.

`Launch` submits one in-desktop application command through the existing
controller session. The command carries literal values, bounded to 40 name bytes,
16 arguments and 8 KiB total, and the owner resolves its admitted catalog. It
requires a live control mount belonging to this execution and never retries: the
reply must identify the same selection and session and name the committed
application and instance. A catalog may mark exactly one desktop per workspace
as the default; a workspace either marks all of its desktops or none.

JSON decoders bound messages to 16 KiB, reject duplicate keys, unknown/case-aliased
contract fields and invalid optional owner resources. Empty Lua grants `{}` means
an empty list; arbitrary objects do not. Operation-specific results are decoded
separately from the common envelope.

Unit/race checks cover sender and reply correlation, owner replacement,
cancellation and no replay, plus strict reply and desktop decoders. The root
`make native-client-check` target also compiles the client fixture and runs it
against a retained owner. The separate `meshmonitorproof` acceptance remains a
required release gate; it currently fails because the pinned runtime sends no
remote EXIT after a client actor completes.

## Session-qualified copy

`Desktop.Copy` requests selected text using the existing `bee.desktop:copy`
operation and the exact live desktop session. It validates the response's owner
execution, workspace, desktop, session, expiry and plain text before returning it.
It does not write the clipboard or replay a request. The physical input worker
performs the write for explicit Ctrl+C; an unselected reply preserves ordinary
application input. A definite selection refusal leaves the client running.

The physical input worker performs the write for explicit Ctrl+C; an unselected
reply preserves ordinary application input. A definite selection refusal leaves
the client running. Copy uses the same serialized call/reply reader as the other
Hive operations.
