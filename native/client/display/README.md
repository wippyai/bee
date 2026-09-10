# Local display connection

`Connect` and `Serve` carry typed terminal input, resize acknowledgments and
retained display snapshots over an already admitted `net.Conn`. The trusted host
supplies a local native `tty.Viewport`; the connection cannot select a PID, grant,
process source or permission. Closing a connection detaches its viewport and
preserves the producer.

One request is in flight per client. Validation and packet encoding precede
sequence consumption. Canceled queued requests do not consume a sequence; failed
writes or lost acknowledgments report uncertain delivery and are never replayed.
An acknowledgment means the viewport accepted the operation, not that an
application processed it. Snapshot delivery coalesces intermediate frames.

Packets, JSON nesting, object members, rows and input sizes are bounded. Strings
are validated as UTF-8. Unknown fields, duplicate fields, contradictory event
fields and malformed numbers are refused. The encoded packet limit also applies
to JSON-escaped paste text, which can be larger than its unescaped input.

Connection closure unblocks network I/O. `Serve` requires a local viewport whose
native operations return promptly: the viewport interface does not provide
cancellation for an arbitrary blocking implementation.

`make -C native check` covers transport behavior with race detection and vet.
`make -C native display-check` additionally exercises the real native TTY service,
including recipient-bound grants and producer retention. Test-only runtime
dependencies use a temporary module file. `display-windows-check` checks Windows
compilation and vet; it does not prove terminal behavior on Windows.

This package does not yet have a public launcher caller. Local endpoint admission,
automatic client profiles, physical terminal mode management and two separate OS
clients remain integration work. It does not enable clustering or solve the
runtime lock-busy error by itself.
