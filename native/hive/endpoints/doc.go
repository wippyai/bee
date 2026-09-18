// SPDX-License-Identifier: MIT

// Package endpoints selects bounded canonical candidate endpoints for Bee invitations.
//
// Intended repository location: native/hive/endpoints
//
// # Role and Boundaries
//
// This package is a small, pure typed leaf for upcoming machine enrollment.
// It is not an enrollment protocol, not an actor router, and not a CLI command.
// Public invitations must advertise listeners that are actually bound; this package
// never scans, allocates, or releases ports, and never binds network sockets.
//
// # Ownership and Liveness
//
// Input listener endpoints must come directly from the live listener owner (for
// example, the active Wippy mesh supervisor or runtime node). Candidate selection
// is a pure computation: it cannot assert listener liveness, socket state, or IP
// ownership from values alone. The caller guarantees that supplied listener
// endpoints correspond to active, bound sockets that will remain held during the
// lifetime of the invitation.
//
// # Candidacy vs Authorization and NAT Limits
//
// Candidates are network reachability hints, not authorization credentials or
// proofs of trust. An advertised endpoint tells a joining machine where to
// attempt contact; it does not grant membership or workspace access. Joining
// machines authenticate the issuer node identity via cryptographic keys and prove
// possession of the one-time invitation capability.
//
// Similarly, candidate selection does not guarantee path reachability or NAT
// traversal. Private LAN (RFC 1918, ULA), global unicast, and overlay (100.64.0.0/10)
// addresses are candidate hints; if two machines lack a shared route or overlay,
// connections fail safely at transport time without compromising security.
// Explicit DNS/host overrides are administrative hints and are never treated as
// authenticated or reachable without successful peer identity verification.
// Overrides always preserve the actual bound port of the listener.
package endpoints
