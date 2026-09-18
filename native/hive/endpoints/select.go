// SPDX-License-Identifier: MIT

package endpoints

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
)

var overlayPrefix = netip.MustParsePrefix("100.64.0.0/10")

// Select performs pure, deterministic candidate endpoint selection for Bee invitations.
//
// Requirements and Contract:
//   - Pure function: does not scan, allocate, or release ports; does not bind sockets;
//     does not enumerate host network interfaces; does not perform network I/O.
//   - Ownership: inputs must come from the live listener owner holding actually bound sockets.
//     Selection cannot assert socket liveness or IP ownership from values alone.
//   - Bounded: input counts and lengths are checked against safety limits; output is deduplicated,
//     ordered deterministically, and capped to MaxCandidates.
//   - Export Mode: excludes loopback, unspecified, multicast, and link-local addresses
//     (IPv6 zone IDs machine-local). Includes private LAN (RFC 1918, ULA), global unicast,
//     and overlay 100.64.0.0/10 addresses (e.g. 100.70.10.28).
//   - Local Mode: retains loopback addresses for single-machine local rendezvous.
//   - Non-wildcard binds: explicit non-wildcard binds are not expanded across all interface addresses.
//   - Wildcard binds: 0.0.0.0 and :: are resolved against eligible caller-supplied interface addresses.
//   - Overrides: intentional hints, never proof of reachability or trust. Overrides always
//     preserve the actual bound port of the listener.
//   - No silently empty export: returns ErrNoExportableEndpoints with an explanatory error.
func Select(params Params) ([]Candidate, error) {
	if params.Mode != ModeExport && params.Mode != ModeLocalOnly {
		return nil, fmt.Errorf("endpoints: invalid selection mode %d", params.Mode)
	}
	// 1. Bound check input collections
	if len(params.Listeners) == 0 {
		return nil, ErrNoListeners
	}
	if len(params.Listeners) > MaxListeners {
		return nil, fmt.Errorf("%w: got %d, max is %d", ErrTooManyListeners, len(params.Listeners), MaxListeners)
	}
	if len(params.Interfaces) > MaxInterfaces {
		return nil, fmt.Errorf("%w: got %d, max is %d", ErrTooManyInterfaces, len(params.Interfaces), MaxInterfaces)
	}
	if len(params.Overrides) > MaxOverrides {
		return nil, fmt.Errorf("%w: got %d, max is %d", ErrTooManyOverrides, len(params.Overrides), MaxOverrides)
	}

	// 2. Validate all listeners
	for i, l := range params.Listeners {
		if !l.Transport.Valid() {
			return nil, fmt.Errorf("%w: listener %d has transport %q", ErrInvalidTransport, i, l.Transport)
		}
		if !l.Endpoint.IsValid() {
			return nil, fmt.Errorf("%w: listener %d has invalid endpoint %v", ErrInvalidListener, i, l.Endpoint)
		}
		if l.Endpoint.Port() == 0 {
			return nil, fmt.Errorf("%w: listener %d (%s) has port zero", ErrZeroPort, i, l.Transport)
		}

		addr := l.Endpoint.Addr()
		if addr.Zone() != "" {
			return nil, fmt.Errorf("%w: listener %d endpoint %s has zone %q", ErrScopedIPv6, i, l.Endpoint, addr.Zone())
		}
		addr = addr.Unmap()
		if addr.IsMulticast() {
			return nil, fmt.Errorf("%w: listener %d endpoint %s is multicast", ErrInvalidListener, i, l.Endpoint)
		}
	}

	// 3. Validate caller-supplied interface addresses
	cleanInterfaces := make([]netip.Addr, 0, len(params.Interfaces))
	for i, iface := range params.Interfaces {
		if !iface.IsValid() {
			return nil, fmt.Errorf("%w: interface address %d is invalid", ErrInvalidListener, i)
		}
		if iface.Zone() != "" {
			// Interface inventories routinely contain scoped link-local addresses.
			// Exclude them without suppressing usable addresses on other interfaces.
			continue
		}
		addr := iface.Unmap()
		if addr.IsMulticast() {
			// Interface address cannot be multicast
			continue
		}
		cleanInterfaces = append(cleanInterfaces, addr)
	}

	var candidates []Candidate

	// 4. Process overrides
	for i, ov := range params.Overrides {
		if ov.Transport != "" && !ov.Transport.Valid() {
			return nil, fmt.Errorf("%w: override %d has invalid transport %q", ErrInvalidTransport, i, ov.Transport)
		}
		ovCandidates, err := processOverride(ov, params.Listeners, params.Mode)
		if err != nil {
			return nil, fmt.Errorf("%w: override %d (%q): %w", ErrInvalidOverride, i, ov.Host, err)
		}
		candidates = append(candidates, ovCandidates...)
	}

	// 5. Process listeners & interface addresses
	for _, l := range params.Listeners {
		boundAddr := l.Endpoint.Addr().Unmap()
		boundPort := l.Endpoint.Port()

		if boundAddr.IsUnspecified() {
			// Wildcard bind: resolve against caller-supplied interface addresses
			isIPv4Wildcard := boundAddr.Is4()
			for _, iface := range cleanInterfaces {
				// Match address family
				if isIPv4Wildcard && !iface.Is4() {
					continue
				}
				if !isIPv4Wildcard && !iface.Is6() {
					continue
				}
				if iface.IsUnspecified() || iface.IsMulticast() {
					continue
				}
				if iface.IsLinkLocalUnicast() {
					// Link-local addresses excluded in all candidate export
					continue
				}

				if params.Mode == ModeExport {
					if iface.IsLoopback() {
						continue
					}
					if isExportableAddr(iface) {
						candidates = append(candidates, Candidate{
							Transport: l.Transport,
							Host:      iface.String(),
							Port:      boundPort,
							Addr:      iface,
						})
					}
				} else {
					// ModeLocalOnly retains loopback
					if iface.IsLoopback() || isExportableAddr(iface) {
						candidates = append(candidates, Candidate{
							Transport: l.Transport,
							Host:      iface.String(),
							Port:      boundPort,
							Addr:      iface,
						})
					}
				}
			}
		} else {
			// Explicit non-wildcard bind: must NOT imply listening on all interfaces!
			if boundAddr.IsLinkLocalUnicast() {
				// Link-local excluded from invitations
				continue
			}

			if params.Mode == ModeExport {
				if boundAddr.IsLoopback() {
					// Loopback excluded in export mode
					continue
				}
				if isExportableAddr(boundAddr) {
					candidates = append(candidates, Candidate{
						Transport: l.Transport,
						Host:      boundAddr.String(),
						Port:      boundPort,
						Addr:      boundAddr,
					})
				}
			} else {
				// ModeLocalOnly retains loopback
				if boundAddr.IsLoopback() || isExportableAddr(boundAddr) {
					candidates = append(candidates, Candidate{
						Transport: l.Transport,
						Host:      boundAddr.String(),
						Port:      boundPort,
						Addr:      boundAddr,
					})
				}
			}
		}
	}

	// 6. Check for empty candidate set
	if len(candidates) == 0 {
		if params.Mode == ModeExport {
			return nil, fmt.Errorf("%w: no eligible private LAN, global, overlay, or override endpoints available; loopback and link-local addresses cannot be exported", ErrNoExportableEndpoints)
		}
		return nil, fmt.Errorf("%w: no usable candidate endpoints found", ErrNoExportableEndpoints)
	}

	// 7. Deduplicate and order deterministically
	ordered := deduplicateAndSort(candidates)

	// 8. Cap output
	if len(ordered) > MaxCandidates {
		return nil, fmt.Errorf("endpoints: %d candidates exceed limit %d; select fewer interfaces or listeners", len(ordered), MaxCandidates)
	}

	return ordered, nil
}

// processOverride parses, validates, and matches an override against bound listeners.
func processOverride(ov Override, listeners []Listener, mode Mode) ([]Candidate, error) {
	raw := ov.Host
	if len(raw) == 0 {
		return nil, errors.New("override host cannot be empty")
	}
	if len(raw) > MaxOverrideLength {
		return nil, fmt.Errorf("%w: length %d exceeds %d", ErrOverrideTooLong, len(raw), MaxOverrideLength)
	}
	if strings.ContainsAny(raw, " \t\r\n\x00/\\") {
		return nil, errors.New("override contains whitespace, control characters, or path separators")
	}

	// Parse host and optional port
	hostStr, explicitPort, err := parseHostPort(raw)
	if err != nil {
		return nil, err
	}

	// Determine if host is an IP address or DNS hostname
	var parsedAddr netip.Addr
	var canonicalHost string
	var isIP bool

	if ip, parseErr := netip.ParseAddr(hostStr); parseErr == nil {
		if ip.Zone() != "" {
			return nil, fmt.Errorf("%w: override IP %s has zone ID", ErrScopedIPv6, ip)
		}
		ip = ip.Unmap()
		if ip.IsMulticast() {
			return nil, errors.New("override address cannot be multicast")
		}
		if ip.IsUnspecified() {
			return nil, errors.New("override address cannot be unspecified (0.0.0.0 or ::)")
		}
		if mode == ModeExport && ip.IsLoopback() {
			return nil, errors.New("loopback override cannot be exported")
		}
		if ip.IsLinkLocalUnicast() {
			return nil, errors.New("link-local override cannot be advertised")
		}
		if !ip.IsLoopback() && !isExportableAddr(ip) {
			return nil, errors.New("override address is not an eligible unicast address")
		}
		canonicalHost = ip.String()
		parsedAddr = ip
		isIP = true
	} else {
		// Validate as DNS hostname
		if err := validateDNSName(hostStr); err != nil {
			return nil, err
		}
		if mode == ModeExport && isLocalhost(hostStr) {
			return nil, errors.New("localhost DNS override cannot be exported")
		}
		canonicalHost = strings.ToLower(strings.TrimSuffix(hostStr, "."))
		parsedAddr = netip.Addr{}
		isIP = false
	}

	// Match against listeners
	var result []Candidate
	matched := false

	for _, l := range listeners {
		if ov.Transport != "" && ov.Transport != l.Transport {
			continue
		}

		boundPort := l.Endpoint.Port()
		if explicitPort != 0 && explicitPort != boundPort {
			return nil, fmt.Errorf("override port %d does not match listener %s actual bound port %d; overrides must preserve actual bound port", explicitPort, l.Transport, boundPort)
		}

		matched = true
		c := Candidate{
			Transport: l.Transport,
			Host:      canonicalHost,
			Port:      boundPort,
		}
		if isIP {
			c.Addr = parsedAddr
		}
		result = append(result, c)
	}

	if !matched {
		return nil, fmt.Errorf("override transport %q does not match any bound listener", ov.Transport)
	}

	return result, nil
}

// parseHostPort separates host from optional port, handling IPv6 bracketed syntax.
func parseHostPort(raw string) (string, uint16, error) {
	// Case 1: [ipv6]:port
	if strings.HasPrefix(raw, "[") && strings.Contains(raw, "]:") {
		h, pStr, err := net.SplitHostPort(raw)
		if err != nil {
			return "", 0, fmt.Errorf("malformed host:port string: %v", err)
		}
		p, err := strconv.ParseUint(pStr, 10, 16)
		if err != nil || p == 0 {
			return "", 0, fmt.Errorf("invalid port in override %q", pStr)
		}
		return h, uint16(p), nil
	}

	// Case 2: [ipv6] without port
	if strings.HasPrefix(raw, "[") && strings.HasSuffix(raw, "]") {
		inner := raw[1 : len(raw)-1]
		if _, err := netip.ParseAddr(inner); err == nil {
			return inner, 0, nil
		}
		return "", 0, fmt.Errorf("malformed bracketed address %q", raw)
	}

	// Case 3: Bare IPv6 address (e.g. "2001:db8::1")
	if _, err := netip.ParseAddr(raw); err == nil {
		return raw, 0, nil
	}

	// Case 4: hostname:port or ipv4:port
	if strings.Contains(raw, ":") {
		h, pStr, err := net.SplitHostPort(raw)
		if err != nil {
			return "", 0, fmt.Errorf("malformed host:port string: %v", err)
		}
		p, err := strconv.ParseUint(pStr, 10, 16)
		if err != nil || p == 0 {
			return "", 0, fmt.Errorf("invalid port in override %q", pStr)
		}
		return h, uint16(p), nil
	}

	// Case 5: Bare hostname or IPv4 without port
	return raw, 0, nil
}

// validateDNSName checks RFC 1035 / RFC 1123 hostname syntax.
func validateDNSName(name string) error {
	trimmed := strings.TrimSuffix(name, ".")
	if len(trimmed) == 0 {
		return errors.New("DNS name cannot be empty")
	}
	if len(trimmed) > 253 {
		return fmt.Errorf("DNS name length %d exceeds maximum 253", len(trimmed))
	}

	labels := strings.Split(trimmed, ".")
	for i, label := range labels {
		if len(label) == 0 {
			return errors.New("DNS name contains empty label")
		}
		if len(label) > 63 {
			return fmt.Errorf("DNS label %q exceeds maximum 63 characters", label)
		}
		if label[0] == '-' || label[len(label)-1] == '-' {
			return fmt.Errorf("DNS label %q cannot start or end with hyphen", label)
		}
		for _, ch := range label {
			if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-') {
				return fmt.Errorf("DNS label %q contains invalid character %q", label, ch)
			}
		}

		// Top-level domain cannot be all-numeric (RFC 1123)
		if i == len(labels)-1 && len(labels) > 1 {
			allDigits := true
			for _, ch := range label {
				if ch < '0' || ch > '9' {
					allDigits = false
					break
				}
			}
			if allDigits {
				return fmt.Errorf("top-level domain %q cannot be all-numeric", label)
			}
		}
	}

	// Single label hostname cannot be purely numeric (e.g. "12345")
	if len(labels) == 1 {
		allDigits := true
		for _, ch := range labels[0] {
			if ch < '0' || ch > '9' {
				allDigits = false
				break
			}
		}
		if allDigits {
			return fmt.Errorf("single-label hostname %q cannot be all-numeric", labels[0])
		}
	}

	return nil
}

// isLocalhost checks whether a hostname resolves to loopback domain semantics.
func isLocalhost(name string) bool {
	lower := strings.ToLower(strings.TrimSuffix(name, "."))
	return lower == "localhost" || strings.HasSuffix(lower, ".localhost")
}

// isExportableAddr checks whether an IP address is eligible for cross-machine export.
func isExportableAddr(addr netip.Addr) bool {
	addr = addr.Unmap()
	if !addr.IsValid() {
		return false
	}
	if addr.Zone() != "" {
		return false
	}
	if addr.IsUnspecified() || addr.IsLoopback() || addr.IsMulticast() || addr.IsLinkLocalUnicast() {
		return false
	}

	// Accept Private LAN (RFC 1918, ULA), Overlay (100.64.0.0/10), or Global Unicast
	return addr.IsPrivate() || isOverlayAddr(addr) || isGlobalUnicast(addr)
}

// isOverlayAddr reports whether addr is in the CGNAT / Overlay prefix 100.64.0.0/10 (RFC 6598).
func isOverlayAddr(addr netip.Addr) bool {
	addr = addr.Unmap()
	return addr.Is4() && overlayPrefix.Contains(addr)
}

// isGlobalUnicast reports whether addr is a globally routable unicast address
// (excluding private LAN and overlay addresses which are handled by dedicated checks).
func isGlobalUnicast(addr netip.Addr) bool {
	addr = addr.Unmap()
	return addr.IsGlobalUnicast() && !addr.IsPrivate() && !isOverlayAddr(addr)
}

type candidateKey struct {
	transport Transport
	host      string
	port      uint16
}

// deduplicateAndSort removes duplicate candidates and applies a strict, deterministic ordering.
func deduplicateAndSort(candidates []Candidate) []Candidate {
	seen := make(map[candidateKey]struct{}, len(candidates))
	unique := make([]Candidate, 0, len(candidates))

	for _, c := range candidates {
		key := candidateKey{
			transport: c.Transport,
			host:      strings.ToLower(c.Host),
			port:      c.Port,
		}
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		unique = append(unique, c)
	}

	slices.SortFunc(unique, compareCandidates)
	return unique
}

// candidateCategory assigns a preference tier for deterministic ordering:
//
//	Tier 1: DNS overrides (IP overrides use their address category)
//	Tier 2: Overlay networks (100.64.0.0/10)
//	Tier 3: Global unicast addresses
//	Tier 4: Private LAN addresses (RFC 1918, ULA)
//	Tier 5: Loopback addresses (local mode)
func candidateCategory(c Candidate) int {
	if !c.Addr.IsValid() {
		// DNS override
		return 1
	}
	addr := c.Addr.Unmap()
	if isOverlayAddr(addr) {
		return 2
	}
	if isGlobalUnicast(addr) {
		return 3
	}
	if addr.IsPrivate() {
		return 4
	}
	if addr.IsLoopback() {
		return 5
	}
	return 6
}

// compareCandidates implements a strict, total ordering:
//  1. Transport string comparison ("gossip" < "internode")
//  2. Category tier (DNS -> overlay -> global -> LAN -> loopback)
//  3. Address family (IPv4 < IPv6)
//  4. Address value (netip.Addr.Compare) or DNS host string
//  5. Port number
func compareCandidates(a, b Candidate) int {
	// 1. Transport
	if a.Transport != b.Transport {
		return strings.Compare(string(a.Transport), string(b.Transport))
	}

	// 2. Category tier
	catA, catB := candidateCategory(a), candidateCategory(b)
	if catA != catB {
		if catA < catB {
			return -1
		}
		return 1
	}

	// 3. Address Family / Host Type
	if a.Addr.IsValid() && b.Addr.IsValid() {
		aUnmap := a.Addr.Unmap()
		bUnmap := b.Addr.Unmap()
		if aUnmap.Is4() && bUnmap.Is6() {
			return -1
		}
		if aUnmap.Is6() && bUnmap.Is4() {
			return 1
		}
		cmp := aUnmap.Compare(bUnmap)
		if cmp != 0 {
			return cmp
		}
	} else if a.Addr.IsValid() && !b.Addr.IsValid() {
		return -1
	} else if !a.Addr.IsValid() && b.Addr.IsValid() {
		return 1
	} else {
		// Both are DNS hosts
		cmp := strings.Compare(strings.ToLower(a.Host), strings.ToLower(b.Host))
		if cmp != 0 {
			return cmp
		}
	}

	// 4. Port
	if a.Port != b.Port {
		if a.Port < b.Port {
			return -1
		}
		return 1
	}

	return 0
}

// HostOverrides creates a slice of Overrides applying to all listener transports.
func HostOverrides(hosts ...string) []Override {
	out := make([]Override, len(hosts))
	for i, h := range hosts {
		out[i] = Override{Host: h}
	}
	return out
}

// NewOverride creates a typed Override scoped to an optional transport.
func NewOverride(host string, transport Transport) Override {
	return Override{Host: host, Transport: transport}
}
