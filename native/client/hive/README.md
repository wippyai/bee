# Native Hive client binding

This `meshclient`-gated package binds the existing `bee.hive@1` protocol to one
native `mesh.Actor`. It creates no transport, principal, listener, database or
application permission. The installed same-account launcher constructs this
binding for native client attachment; external enrollment remains unfinished.

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
binding tests. The separate-runtime physical fixture also proves supervisor
admission, destination shell input, F12 presenter replacement with the same shell,
resize and bounded detach on runtime `674b58a1`. This uses explicit disposable
enrollment; it does not establish public remote enrollment.

Build the compiled fixture through
`make -C native hive-desktop-client-fixture MESH_RUNTIME=... FIXTURE_OUTPUT=...`.
Run it with `tests/fixtures/hive_desktop_admission/physical.py` through
`make hive-desktop-admission-check`. The physical F12 oracle renders complete
frames and compares test-only presenter identity, since unchanged shell cells
need not be emitted again.

The crash variant retains one replacement client process during admission
cleanup. Only typed explicit refusals can be retried with new mutation keys;
uncertain outcomes stop the proof. Its bounded retries allow the documented
40-second node-departure window, not immediate exact-actor exit. Restarting the
replacement for each refusal previously introduced same-name/new-port membership
conflicts and could not isolate attachment cleanup. That native rejoin case
remains separate. See the current evidence in
[the handoff](../../../docs/handoffs/JOURNAL.md).

## Session-qualified copy

`Desktop.Copy` requests selected text using the existing `bee.desktop:copy`
operation and the exact live desktop session. It validates the response's owner
execution, workspace, desktop, session, expiry and plain text before returning it.
It does not write the clipboard or replay a request. The physical input worker
performs the write for explicit Ctrl+C; an unselected reply preserves ordinary
application input. A definite selection refusal leaves the client running.

The installed candidate includes this operation and passes selected-window copy
acceptance. Copy uses the same serialized call/reply reader. Release runtime
cutover and public remote selection remain separate gates.
