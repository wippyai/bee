# Native Hive client binding

This `meshclient`-gated package binds the existing `bee.hive@1` protocol to one
native `mesh.Actor`. It creates no transport, principal, listener, database or
application permission. Public launch does not construct it yet.

`New(lifetime, actor, ownerNode)` receives a cancellable context owned by the
client actor's caller. One binding exclusively consumes that actor's control
inbox. Calls use bounded, cancellable serialization and a 30-second ceiling,
send once, authenticate the exact supervisor PID from native discovery, correlate
the reply and recheck that supervisor before accepting it. A replacement owner
retires the binding. Native Wippy supplies sender identity and transport security;
there is no ingress API or connection credential in Bee's message contract.

`UnknownOutcome` retains the operation and idempotency key when transport accepted
a request but no trustworthy completion arrived. It does not trigger replay.
`Reply.Done()` and `DesktopMount.Done()` describe the caller-owned actor lifetime,
not connection liveness, remote revocation or permission. The physical caller must
end that lifetime on actor/transport shutdown. Native viewport grants enforce
actual observation/input/resize rights at use time.

`NewDesktop` additionally binds owner execution and physical actor identity.
`List`, `Attach` and `Detach` validate workspace, desktop, recipient, session, mode
and expiry. A node's catalog can contain multiple workspaces. Ordinary typed
refusals remain distinct from uncertain mutations. No method owns the terminal,
starts a workspace or retries a mutation.

JSON decoders bound messages to 16 KiB, reject duplicate keys, unknown/case-aliased
contract fields and invalid optional owner resources. Empty Lua grants `{}` means
an empty list; arbitrary objects do not. Operation-specific results are decoded
separately from the common envelope.

Run `make -C native hive-client-check MESH_RUNTIME=/path/to/client-runtime`.
Unit/race checks cover sender and reply correlation, owner replacement,
cancellation and no replay, plus strict reply and desktop decoders. These are
binding tests; actual supervisor round trips, physical attachment, invitation
redemption and public second-`bee` behavior still need integration acceptance.
The ordinary desktop runtime candidate lacks native mesh surface/TLS APIs; use
the client runtime supplied by its lane without changing the release manifest.

The compiled `testfixture` now builds through
`make -C native hive-desktop-client-fixture MESH_RUNTIME=... FIXTURE_OUTPUT=...`.
The runtime lane's `/tmp/bee-wippy-tls-lifecycle-candidate` now passes the real
supervisor round trip with this compiled client: admission, native viewport IO,
detach and same-shell rejoin (`/tmp/bee-tls-lifecycle-admission.log`, journal 559).
It fixes the earlier TLS mismatch; no TLS bypass or ingress API is needed.

The physical PTY variant reaches the shell, but F12 replacement currently misses
presenter readiness and pauses the desktop
(`/tmp/bee-physical-tls-lifecycle-check.log`). An isolated trace pins the stall to the replacement presenter's `tty.start()`:
it does not reach surface creation or readiness. The candidate still has the
single terminal worker shared with `io.readline()`; runtime #701 addresses this
exact blocked-read/F12 case. Production Bee timeouts remain unchanged. The runtime candidate also retains six lint issues and unfinished
cluster load/recovery validation; it is not a release pin. Public launch remains
unimplemented, including the owner-lock/client transition.

## Session-qualified copy

`Desktop.Copy` requests selected text using the existing `bee.desktop:copy`
operation and the exact live desktop session. It validates the response's owner
execution, workspace, desktop, session, expiry and plain text before returning it.
It does not write the clipboard or replay a request. The physical input worker
performs the write for explicit Ctrl+C; an unselected reply preserves ordinary
application input. A definite selection refusal leaves the client running.

The current external Bee source must include this owner operation, the retained
input marker and presenter response path. Ordinary public releases do not expose
it yet. The separate unsolicited inbox experiment was removed; copy uses the
same existing serialized call/reply reader. Full selected-window acceptance still
requires the combined launcher/clipboard runtime.
