// SPDX-License-Identifier: MIT

// Package owner connects an already admitted local net.Conn acceptor to an
// actual Lua process-owned native TTY viewport.
//
// # Problem and Scope
//
// In multi-client Hive/Bee environments, secondary invocations connect to an
// active workspace owner through an admitted local net.Conn. This package
// bridges the admitted connection to a process-owned native tty.Viewport
// created with the actual caller's execution frame context.
//
// The package explicitly DOES NOT implement:
//   - Connection authentication or TLS termination (handled by outer lane)
//   - Actor mesh routing or discovery (uses standard native/ioevents subscription pattern)
//   - Wire-selected PIDs, grants, policies, or process source identifiers
//   - Listener factory ownership (listener stays owned externally)
//
// # Trust Boundary and Security Guarantees
//
//   - Only callers granted the exact security action "bee.local.accept" on
//     resource "bee.local:listener" can accept connections.
//   - Native tty.Service.Create is invoked with the ACTUAL caller frame context,
//     never a fabricated PID.
//   - The producer viewport grant is returned exclusively to in-process Lua via
//     Attachment:grant() and is NEVER exposed on the physical wire.
//   - The physical wire protocol (bee.display.v1 via display.Serve) handles the
//     underlying connection; it cannot choose the display or actor.
//   - Attachment handles cannot be invoked from another caller frame. Owner PID
//     and epoch are strictly verified on every method call.
//
// # Lifecycle and Capacity Guarantees
//
//   - Pending and active connections are bounded to a maximum of 32 total.
//   - All blocking operations (Accept, handshake, Serve) run asynchronously off
//     the scheduler thread.
//   - Dual-independent cleanup: both the process subscription cleanup
//     (SubscribeRouted / SetSubscriptionCleanup) and the Manager/handler lifecycle
//     hold independent cleanup hooks to prevent connection or viewport leaks.
//   - Detached consumers never terminate underlying producer processes.
//   - Manager.Stop joins all active display.Serve goroutines cleanly.
package owner
