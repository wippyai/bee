// SPDX-License-Identifier: MIT

// Package display implements an isolated local display transport bridge for Wippy
// and Bee terminal sessions over an arbitrary net.Conn.
//
// # Problem and Scope
//
// In Hive multi-client architectures, an ordinary bee invocation encountering an
// active workspace owner hits the runtime exclusive state lock. Rather than starting
// duplicate runtimes or bypassing the lock, secondary invocations attach their local
// physical terminal to one of the independently owned client actors (e.g. bee.client:main)
// hosted within the primary runtime.
//
// This package provides the isolated, terminal-only transport layer for an ALREADY
// admitted local connection. It explicitly DOES NOT implement:
//   - General actor message routing or mesh discovery
//   - Remote workspace admission or authentication handshake
//   - Socket rendezvous or filesystem listener discovery
//   - Credential enrollment or token redemption
//   - Process spawning, database profile management, or CLI subcommands
//
// Pre-admission is outside the prototype boundary: trusted host code is responsible
// for authenticating the invoking terminal process and resolving its grant/handle before
// supplying the native tty.Viewport to Serve.
//
// # Trust Boundary and Wire Guarantees
//
// Only trusted host code can supply a tty.Viewport. The wire protocol never accepts
// a PID, viewport handle, grant token, policy object, or process source identifier.
//
// Wire guarantees include:
//   - Bounded packet length checked BEFORE any memory allocation.
//   - Strict wire decode rejecting unknown fields, duplicate fields, case-aliased fields,
//     null required fields, invalid UTF-8, and trailing or malformed content.
//   - Bounded JSON structure: maximum recursion depth 8, maximum object members 16,
//     and maximum array elements bounded to MaxRows early.
//   - Exact handshake protocol version validation ("bee.display.v1").
//   - Monotonically increasing input sequence numbers with per-input acknowledgments.
//     Input acceptance means viewport.Send or viewport.Resize returned, not application
//     processing. Ambiguous delivery on connection failure is exposed as ErrUncertainDelivery
//     without automatic retries.
//   - Channel semaphore serialization ensuring at most one in-flight request per connection
//     with no sequence gaps for pre-admission cancellations.
//   - Snapshot frame coalescing under transport backpressure: host producer writes to
//     virtual ports remain non-blocking while the bridge writer delivers the latest
//     retained revision and cursor.
//   - Clean unblocking shutdown using net.Conn.Close, joining all owned goroutines without
//     terminating the underlying producer process.
//   - The supplied viewport must be LOCAL as native Send has no cancellable interface;
//     cancellation unblocks network I/O and detaches the attachment, but cannot interrupt
//     arbitrary blocking remote viewports.
package display
