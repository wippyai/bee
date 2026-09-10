// SPDX-License-Identifier: MIT

// Package local provides local physical-client rendezvous and mutual authentication
// for a single runtime owner holding its exclusive application-state lock.
//
// Authority and Boundaries:
// This package handles local physical-client rendezvous and transport authentication only.
// It is NOT responsible for workspace/client actor admission, session permissions, or cluster
// membership; higher-level workspace authorization is granted subsequently by a trusted supervisor.
//
// Security Model:
// Protection of the published endpoint descriptor relies on native OS user filesystem authority
// (owner-only permissions via internal/privatefile). This package makes no false sandbox claims:
// any process executing under the same OS user account is trusted and has access to the descriptor.
// It does not defend against an untrusted shell running under the same user account.
//
// Prerequisite:
// Ownership of the runtime host application-state lock is an explicit prerequisite before
// invoking Start. This package never acquires, inspects, or releases the runtime lock, nor does
// it invent a second host lock.
//
// Ephemeral Rotated Identity:
// Each runtime run generates a fresh, ephemeral Ed25519 keypair and self-signed CA certificate
// with server and client auth usages and localhost name. The certificate acts as the mutual TLS
// trust root for that specific run. Because identity is rotated on every invocation, stale
// descriptors from prior runs or crashed instances cannot authenticate to a replacement listener.
//
// Descriptor Lifecycle:
// Start binds TCP 127.0.0.1:0 and publishes the protected endpoint descriptor only after socket
// and TLS configuration succeed. On Close, the descriptor is retained intentionally on disk:
// removing it could race a subsequent runtime owner starting concurrently, and stale presence
// never proves liveness.
//
// Concurrency & Accept Contract:
// Accept implements an explicit single-Accept contract guarded against concurrent invocations
// to eliminate global deadline races. Handshake timeouts are strictly bounded, and pending
// handshakes are tracked so slow or malicious clients cannot monopolize the listener.
// Context cancellation unblocks pending accepts and handshakes promptly via stop-and-join watchers.
// Accepted connections transfer full ownership to the caller and survive setup context cancellation
// or listener closure.
package local
