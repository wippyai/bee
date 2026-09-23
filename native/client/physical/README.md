# Native physical client candidate

This package is gated by `physicalclient` pending public startup integration.
The combined candidate uses it for ordinary Bee startup; the release manifest
has not switched to this component yet.

`Run` presents an admitted Wippy native mesh viewport using the runtime surface
and input reader. It imports no Bee display protocol and creates no listener.
The caller supplies the recipient's live runtime frame and selected observation,
input and resize rights. The native grant authorizes those rights before terminal
setup and checks operations during use. Observer clients forward neither input
nor resize; Ctrl+] and Ctrl+Q detach locally, including while host input is stalled.
These physical-client exits retain the owner and its applications.

Input admission is bounded by a 256-slot queue and 2 MiB of outstanding event
data. The worker retains each byte charge until delivery completes. Overflow
cancels delivery and detaches without replay. Cleanup cancels native operations,
joins the worker, then closes the viewport and restores terminal modes. This
prevents local viewport closure from revoking an operation still unwinding its
cancellation. Genuine operation errors survive a
concurrent mount retirement. Cancellation is not proof that pending input was
unapplied, and nothing retries it automatically.

The caller owns stdin/stdout, actor admission and outer cancellation, including
signals. `Run` owns only the viewport attachment; closing it does not terminate
the producer. It reads the initial cached snapshot and subsequent coalesced
update notifications. It allocates no client database or discovery state.
Terminal output must remain writable; arbitrary blocking writers cannot be
interrupted by this adapter.

Against the reviewed runtime checkout containing `terminal.NewEventInputReader`:

```
make -C native physical-client-check PHYSICAL_RUNTIME=/absolute/runtime/checkout
```

Real PTY checks cover stalled-operation detach, terminal restoration, preserved
delivery errors, observers and denied control. A real runtime viewport check over
a test-only in-memory mesh pair additionally verifies foreign-recipient denial,
mount retirement and fresh attachment to retained owner content. This is not a
separate OS-process or LAN acceptance test. CLI admission and startup composition
remain required before public activation.

Separate OS-process native mesh composition is checked in [mesh](../mesh/README.md),
using fixture-selected grants. Public supervisor admission remains unfinished.
