// SPDX-License-Identifier: MIT

package endpoints

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
)

// Bounds and capacity limits to guarantee bounded computation and defense in depth.
const (
	// MaxListeners is the maximum number of bound listeners accepted as input.
	MaxListeners = 32

	// MaxInterfaces is the maximum number of caller-supplied interface addresses.
	MaxInterfaces = 128

	// MaxOverrides is the maximum number of caller-supplied overrides.
	MaxOverrides = 32

	// MaxOverrideLength is the maximum length of an override string in characters
	// (matching the RFC 1035 DNS name limit of 253 octets).
	MaxOverrideLength = 253

	// MaxCandidates is the maximum number of candidate endpoints returned in the
	// deduplicated, deterministically ordered result.
	MaxCandidates = 64
)

// Transport identifies the protocol role for a Bee listener.
type Transport string

const (
	// TransportGossip is the cluster membership gossip transport (TCP/UDP).
	TransportGossip Transport = "gossip"

	// TransportInternode is the inter-node peer transport for RPC, messaging, and Raft (TCP).
	TransportInternode Transport = "internode"
)

// Valid reports whether the transport is recognized by Bee Hive topology.
func (t Transport) Valid() bool {
	switch t {
	case TransportGossip, TransportInternode:
		return true
	default:
		return false
	}
}

// String implements fmt.Stringer for Transport.
func (t Transport) String() string {
	return string(t)
}

// Mode defines endpoint filtering rules based on the invitation's scope.
type Mode int

const (
	// ModeExport selects candidates suitable for cross-machine invitations.
	// Loopback, unspecified, multicast, and link-local addresses (including
	// scoped IPv6 zone IDs) are excluded. Private LAN (RFC 1918, ULA), global
	// unicast, and overlay (100.64.0.0/10) addresses are included.
	ModeExport Mode = iota

	// ModeLocalOnly retains loopback addresses for local single-machine rendezvous.
	// Unspecified, multicast, and scoped/link-local addresses remain excluded.
	ModeLocalOnly
)

// String implements fmt.Stringer for Mode.
func (m Mode) String() string {
	switch m {
	case ModeExport:
		return "export"
	case ModeLocalOnly:
		return "local-only"
	default:
		return fmt.Sprintf("mode(%d)", m)
	}
}

// Listener represents an actually bound listener endpoint owned by the caller.
//
// Ownership requirement:
// Inputs must come from the live listener owner. Selection is a pure computation
// and cannot assert socket liveness or OS ownership from values alone.
type Listener struct {
	Transport Transport
	Endpoint  netip.AddrPort
}

// String implements fmt.Stringer for Listener.
func (l Listener) String() string {
	return fmt.Sprintf("%s=%s", l.Transport, l.Endpoint)
}

// Override represents an optional explicit DNS hostname or address override.
//
// Overrides are intentional hints provided by configuration or an administrator;
// they are never proof of reachability or trust. Overrides always preserve the
// actual bound port of the associated listener.
type Override struct {
	// Host is an explicit DNS hostname (e.g. "seed.example.com") or IP address
	// (e.g. "100.70.10.28", "2001:db8::1"). It may optionally include a port that
	// matches the listener's bound port; mismatched ports are rejected.
	Host string

	// Transport optionally scopes this override to a specific transport.
	// If empty (""), the override applies to all bound listener transports.
	Transport Transport
}

// String implements fmt.Stringer for Override.
func (o Override) String() string {
	if o.Transport == "" {
		return o.Host
	}
	return fmt.Sprintf("%s=%s", o.Transport, o.Host)
}

// Candidate is a canonical, typed candidate endpoint for an invitation.
// Candidates are network reachability hints preserving transport identity.
// They carry no authorization or trust.
type Candidate struct {
	// Transport identifies the protocol role (gossip or internode).
	Transport Transport

	// Host is the canonical host string: an unbracketed IP address or a DNS hostname.
	Host string

	// Port is the actual bound port (1-65535), preserved from the live listener.
	Port uint16

	// Addr is the parsed IP address if Host is an IP address. If Host is a DNS
	// hostname, Addr is netip.Addr{} (Addr.IsValid() == false).
	Addr netip.Addr
}

// IsIP reports whether the candidate host is an IP address.
func (c Candidate) IsIP() bool {
	return c.Addr.IsValid()
}

// IsDNS reports whether the candidate host is a DNS hostname.
func (c Candidate) IsDNS() bool {
	return !c.Addr.IsValid()
}

// AddrPort returns the netip.AddrPort representation if the candidate is an IP address.
// If the candidate is a DNS hostname, it returns false.
func (c Candidate) AddrPort() (netip.AddrPort, bool) {
	if !c.Addr.IsValid() {
		return netip.AddrPort{}, false
	}
	return netip.AddrPortFrom(c.Addr, c.Port), true
}

// Endpoint returns the canonical host:port endpoint string.
// IPv6 addresses are properly enclosed in brackets (e.g. "[2001:db8::1]:7946").
func (c Candidate) Endpoint() string {
	return net.JoinHostPort(c.Host, strconv.Itoa(int(c.Port)))
}

// String implements fmt.Stringer, returning the canonical host:port representation.
func (c Candidate) String() string {
	return c.Endpoint()
}

// Params configures pure candidate endpoint selection.
type Params struct {
	// Mode specifies whether candidates are intended for export or local rendezvous.
	Mode Mode

	// Listeners is the set of actual bound listener endpoints held by the caller.
	// Must contain at least one listener. Inputs must come from the live listener owner.
	Listeners []Listener

	// Interfaces is the set of caller-supplied local interface addresses.
	// Used to resolve wildcard listener binds (0.0.0.0 or ::). Pure selection
	// does not enumerate network interfaces.
	Interfaces []netip.Addr

	// Overrides contains optional explicit DNS or IP address hints.
	// Overrides are intentional hints, never proof of reachability or trust,
	// and preserve the actual bound port of the listener.
	Overrides []Override
}

// Sentinel errors.
var (
	// ErrNoListeners indicates that no listeners were provided in selection params.
	ErrNoListeners = errors.New("endpoints: at least one bound listener endpoint must be provided")

	// ErrTooManyListeners indicates the listener count exceeds MaxListeners.
	ErrTooManyListeners = errors.New("endpoints: listener count exceeds maximum limit")

	// ErrTooManyInterfaces indicates the interface count exceeds MaxInterfaces.
	ErrTooManyInterfaces = errors.New("endpoints: interface address count exceeds maximum limit")

	// ErrTooManyOverrides indicates the override count exceeds MaxOverrides.
	ErrTooManyOverrides = errors.New("endpoints: override count exceeds maximum limit")

	// ErrOverrideTooLong indicates an override string exceeds MaxOverrideLength.
	ErrOverrideTooLong = errors.New("endpoints: override string exceeds maximum length")

	// ErrInvalidOverride indicates an override is malformed, has invalid syntax, or attempts port alteration.
	ErrInvalidOverride = errors.New("endpoints: invalid override")

	// ErrInvalidTransport indicates an unrecognized or empty transport was supplied.
	ErrInvalidTransport = errors.New("endpoints: invalid or unsupported transport")

	// ErrInvalidListener indicates a listener endpoint is uninitialized, invalid, or multicast.
	ErrInvalidListener = errors.New("endpoints: invalid listener endpoint")

	// ErrZeroPort indicates a listener port is zero. Listeners must be actually bound.
	ErrZeroPort = errors.New("endpoints: listener port cannot be zero; must be actually bound")

	// ErrScopedIPv6 indicates a scoped IPv6 address with a machine-local zone ID was provided.
	ErrScopedIPv6 = errors.New("endpoints: scoped IPv6 address with zone ID cannot be advertised")

	// ErrNoExportableEndpoints indicates that candidate selection yielded no exportable endpoints.
	ErrNoExportableEndpoints = errors.New("endpoints: no exportable candidate endpoints found")
)
