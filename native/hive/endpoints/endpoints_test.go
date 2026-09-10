// SPDX-License-Identifier: MIT

package endpoints_test

import (
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/hive/endpoints"
)

// Helper constructors for concise test definitions.
func ap(s string) netip.AddrPort {
	return netip.MustParseAddrPort(s)
}

func addr(s string) netip.Addr {
	return netip.MustParseAddr(s)
}

// 1. Wildcard IPv4: 0.0.0.0 resolves to eligible caller-supplied IPv4 interfaces.
func TestWildcardIPv4(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
	}
	interfaces := []netip.Addr{
		addr("127.0.0.1"),     // loopback (excluded in export)
		addr("192.168.1.50"),  // private LAN
		addr("10.0.0.2"),      // private LAN
		addr("169.254.10.20"), // link-local (excluded)
		addr("2001:db8::1"),   // IPv6 (ignored for IPv4 wildcard)
	}

	got, err := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listeners,
		Interfaces: interfaces,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("expected 2 candidates, got %d: %+v", len(got), got)
	}

	for _, c := range got {
		if c.Transport != endpoints.TransportGossip {
			t.Errorf("expected gossip transport, got %s", c.Transport)
		}
		if c.Port != 7946 {
			t.Errorf("expected port 7946, got %d", c.Port)
		}
		if c.Host != "10.0.0.2" && c.Host != "192.168.1.50" {
			t.Errorf("unexpected candidate host %s", c.Host)
		}
	}
}

// 2. Wildcard IPv6: [::] resolves to eligible caller-supplied IPv6 interfaces.
func TestWildcardIPv6(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportInternode, Endpoint: ap("[::]:7947")},
	}
	interfaces := []netip.Addr{
		addr("::1"),               // loopback (excluded in export)
		addr("2600:1f18::10"),     // global unicast IPv6
		addr("fd12:3456:789a::1"), // IPv6 ULA (private LAN)
		addr("fe80::1"),           // link-local IPv6 (excluded)
		addr("192.168.1.50"),      // IPv4 (ignored for IPv6 wildcard)
	}

	got, err := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listeners,
		Interfaces: interfaces,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("expected 2 candidates, got %d: %+v", len(got), got)
	}

	for _, c := range got {
		if c.Transport != endpoints.TransportInternode {
			t.Errorf("expected internode transport, got %s", c.Transport)
		}
		if c.Port != 7947 {
			t.Errorf("expected port 7947, got %d", c.Port)
		}
		if c.Host != "2600:1f18::10" && c.Host != "fd12:3456:789a::1" {
			t.Errorf("unexpected candidate host %s", c.Host)
		}
		// Check proper IPv6 bracketed endpoint representation
		expectedEndpoint := fmt.Sprintf("[%s]:7947", c.Host)
		if c.Endpoint() != expectedEndpoint {
			t.Errorf("expected endpoint %q, got %q", expectedEndpoint, c.Endpoint())
		}
	}
}

// 3. Exact binds: explicit non-wildcard binds must NOT imply listening on all interfaces.
func TestExactBinds(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("192.168.1.50:7946")},
	}
	// Caller supplies multiple interfaces; only the exact bound address must become a candidate.
	interfaces := []netip.Addr{
		addr("192.168.1.50"),
		addr("10.0.0.1"),
		addr("172.16.0.1"),
		addr("100.70.10.28"),
	}

	got, err := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listeners,
		Interfaces: interfaces,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(got) != 1 {
		t.Fatalf("expected exactly 1 candidate for exact bind, got %d: %+v", len(got), got)
	}
	if got[0].Host != "192.168.1.50" || got[0].Port != 7946 {
		t.Errorf("expected 192.168.1.50:7946, got %s:%d", got[0].Host, got[0].Port)
	}
}

// 4. Overlay: 100.64.0.0/10 (such as 100.70.10.28) is included in export candidates.
func TestOverlayAddress(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportInternode, Endpoint: ap("100.70.10.28:7947")},
	}

	got, err := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(got) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(got))
	}
	if got[0].Host != "100.70.10.28" || got[0].Port != 7947 {
		t.Errorf("expected 100.70.10.28:7947, got %s:%d", got[0].Host, got[0].Port)
	}
	if got[0].Endpoint() != "100.70.10.28:7947" {
		t.Errorf("expected endpoint string 100.70.10.28:7947, got %q", got[0].Endpoint())
	}
}

// 5. Loopback-only export rejection: export mode refuses silently empty invitations.
func TestLoopbackOnlyExportRejection(t *testing.T) {
	// Subcase A: Exact loopback bind
	listenersA := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("127.0.0.1:7946")},
	}
	_, errA := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listenersA,
	})
	if errA == nil {
		t.Fatalf("expected error exporting loopback listener, got nil")
	}
	if !errors.Is(errA, endpoints.ErrNoExportableEndpoints) {
		t.Errorf("expected ErrNoExportableEndpoints, got %v", errA)
	}

	// Subcase B: Wildcard bind with only loopback interfaces
	listenersB := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
	}
	interfacesB := []netip.Addr{
		addr("127.0.0.1"),
		addr("127.0.0.2"),
	}
	_, errB := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listenersB,
		Interfaces: interfacesB,
	})
	if errB == nil {
		t.Fatalf("expected error exporting wildcard with only loopback interfaces, got nil")
	}
	if !errors.Is(errB, endpoints.ErrNoExportableEndpoints) {
		t.Errorf("expected ErrNoExportableEndpoints, got %v", errB)
	}
}

// 6. Local-only mode retains loopback addresses.
func TestLocalOnlyModeRetainsLoopback(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("127.0.0.1:7946")},
		{Transport: endpoints.TransportInternode, Endpoint: ap("[::1]:7947")},
	}

	got, err := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeLocalOnly,
		Listeners: listeners,
	})
	if err != nil {
		t.Fatalf("unexpected error in local-only mode: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("expected 2 candidates in local-only mode, got %d: %+v", len(got), got)
	}

	endpointsExpected := []string{"127.0.0.1:7946", "[::1]:7947"}
	for _, c := range got {
		if !slices.Contains(endpointsExpected, c.Endpoint()) {
			t.Errorf("unexpected endpoint %q", c.Endpoint())
		}
	}
}

// 7. Scoped IPv6 rejection: zone IDs are machine-local and must be rejected.
func TestScopedIPv6Rejection(t *testing.T) {
	scopedAddr, err := netip.ParseAddr("fe80::1%eth0")
	if err != nil {
		t.Fatalf("failed to parse scoped test address: %v", err)
	}

	// Subcase A: Listener with scoped address
	_, errListener := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: netip.AddrPortFrom(scopedAddr, 7946)},
		},
	})
	if errListener == nil {
		t.Fatalf("expected error for scoped listener endpoint, got nil")
	}
	if !errors.Is(errListener, endpoints.ErrScopedIPv6) {
		t.Errorf("expected ErrScopedIPv6, got %v", errListener)
	}

	// Subcase B: Interface address with scoped address
	_, errIface := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
		},
		Interfaces: []netip.Addr{scopedAddr},
	})
	if errIface == nil {
		t.Fatalf("expected error for scoped interface address, got nil")
	}
	if !errors.Is(errIface, endpoints.ErrNoExportableEndpoints) {
		t.Errorf("expected no exportable addresses after filtering, got %v", errIface)
	}

	// Subcase C: Override with scoped address
	_, errOverride := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
		},
		Overrides: []endpoints.Override{
			{Host: "fe80::1%eth0"},
		},
	})
	if errOverride == nil {
		t.Fatalf("expected error for scoped override address, got nil")
	}
	if !errors.Is(errOverride, endpoints.ErrScopedIPv6) {
		t.Errorf("expected ErrScopedIPv6, got %v", errOverride)
	}
}

// 8. Actual bound port retention: overrides cannot alter the bound port.
func TestActualBoundPortRetention(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
		{Transport: endpoints.TransportInternode, Endpoint: ap("0.0.0.0:7947")},
	}

	// Subcase A: Host override without port adopts each listener's actual bound port
	got, err := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
		Overrides: []endpoints.Override{
			{Host: "seed.example.com"},
		},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(got) != 2 {
		t.Fatalf("expected 2 candidates (one per transport), got %d: %+v", len(got), got)
	}
	if got[0].Endpoint() != "seed.example.com:7946" || got[0].Transport != endpoints.TransportGossip {
		t.Errorf("expected gossip seed.example.com:7946, got %s %s", got[0].Transport, got[0].Endpoint())
	}
	if got[1].Endpoint() != "seed.example.com:7947" || got[1].Transport != endpoints.TransportInternode {
		t.Errorf("expected internode seed.example.com:7947, got %s %s", got[1].Transport, got[1].Endpoint())
	}

	// Subcase B: Matching explicit port in override is accepted
	gotB, errB := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")}},
		Overrides: []endpoints.Override{
			{Host: "seed.example.com:7946"},
		},
	})
	if errB != nil {
		t.Fatalf("unexpected error with matching port: %v", errB)
	}
	if len(gotB) != 1 || gotB[0].Port != 7946 {
		t.Errorf("expected port 7946, got %+v", gotB)
	}

	// Subcase C: Mismatched explicit port in override is rejected
	_, errC := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")}},
		Overrides: []endpoints.Override{
			{Host: "seed.example.com:9999"},
		},
	})
	if errC == nil {
		t.Fatalf("expected error when override port mismatches listener bound port, got nil")
	}
	if !errors.Is(errC, endpoints.ErrInvalidOverride) {
		t.Errorf("expected ErrInvalidOverride, got %v", errC)
	}
}

// 9. Zero port and invalid listener input rejection.
func TestZeroPortAndInvalidListeners(t *testing.T) {
	// Zero port
	_, errZero := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: ap("192.168.1.1:0")},
		},
	})
	if errZero == nil {
		t.Fatalf("expected error for port 0, got nil")
	}
	if !errors.Is(errZero, endpoints.ErrZeroPort) {
		t.Errorf("expected ErrZeroPort, got %v", errZero)
	}

	// Uninitialized / invalid endpoint
	_, errInvalid := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: netip.AddrPort{}},
		},
	})
	if errInvalid == nil {
		t.Fatalf("expected error for uninitialized endpoint, got nil")
	}
	if !errors.Is(errInvalid, endpoints.ErrInvalidListener) {
		t.Errorf("expected ErrInvalidListener, got %v", errInvalid)
	}

	// Multicast listener
	_, errMcast := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: ap("224.0.0.1:7946")},
		},
	})
	if errMcast == nil {
		t.Fatalf("expected error for multicast listener, got nil")
	}
	if !errors.Is(errMcast, endpoints.ErrInvalidListener) {
		t.Errorf("expected ErrInvalidListener, got %v", errMcast)
	}

	// Invalid transport
	_, errTrans := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: "unknown-proto", Endpoint: ap("192.168.1.1:7946")},
		},
	})
	if errTrans == nil {
		t.Fatalf("expected error for unknown transport, got nil")
	}
	if !errors.Is(errTrans, endpoints.ErrInvalidTransport) {
		t.Errorf("expected ErrInvalidTransport, got %v", errTrans)
	}
}

// 10. Duplicate cases: candidates are deduplicated.
func TestDuplicateCases(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")}, // duplicate listener
	}
	interfaces := []netip.Addr{
		addr("192.168.1.50"),
		addr("192.168.1.50"), // duplicate interface
	}
	overrides := []endpoints.Override{
		{Host: "192.168.1.50"}, // duplicate of resolved interface
		{Host: "seed.example.com"},
		{Host: "seed.example.com"}, // duplicate override
	}

	got, err := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listeners,
		Interfaces: interfaces,
		Overrides:  overrides,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should contain exactly 2 distinct candidates:
	// 1. seed.example.com:7946 (DNS override, Tier 1)
	// 2. 192.168.1.50:7946 (Private LAN, Tier 4)
	if len(got) != 2 {
		t.Fatalf("expected 2 deduplicated candidates, got %d: %+v", len(got), got)
	}
	if got[0].Endpoint() != "seed.example.com:7946" {
		t.Errorf("expected first candidate seed.example.com:7946, got %s", got[0].Endpoint())
	}
	if got[1].Endpoint() != "192.168.1.50:7946" {
		t.Errorf("expected second candidate 192.168.1.50:7946, got %s", got[1].Endpoint())
	}
}

// 11. Oversize cases: input bounds and output capping.
func TestOversizeCases(t *testing.T) {
	// Subcase A: Override string too long (> 253 characters)
	longName := strings.Repeat("a", 250) + ".example.com"
	_, errLong := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
		},
		Overrides: []endpoints.Override{{Host: longName}},
	})
	if errLong == nil {
		t.Fatalf("expected error for oversized override string, got nil")
	}
	if !errors.Is(errLong, endpoints.ErrInvalidOverride) {
		t.Errorf("expected ErrInvalidOverride, got %v", errLong)
	}

	// Subcase B: Too many listeners (> MaxListeners = 32)
	manyListeners := make([]endpoints.Listener, 33)
	for i := range manyListeners {
		manyListeners[i] = endpoints.Listener{
			Transport: endpoints.TransportGossip,
			Endpoint:  netip.AddrPortFrom(addr("192.168.1.1"), uint16(1000+i)),
		}
	}
	_, errManyL := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: manyListeners,
	})
	if !errors.Is(errManyL, endpoints.ErrTooManyListeners) {
		t.Errorf("expected ErrTooManyListeners, got %v", errManyL)
	}

	// Subcase C: Too many interfaces (> MaxInterfaces = 128)
	manyInterfaces := make([]netip.Addr, 129)
	for i := range manyInterfaces {
		manyInterfaces[i] = addr("10.0.0.1")
	}
	_, errManyI := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")}},
		Interfaces: manyInterfaces,
	})
	if !errors.Is(errManyI, endpoints.ErrTooManyInterfaces) {
		t.Errorf("expected ErrTooManyInterfaces, got %v", errManyI)
	}

	// Subcase D: Refuse overflow rather than silently drop transport candidates.
	largeIfaces := make([]netip.Addr, 100)
	for i := range largeIfaces {
		// Generate distinct private IPs: 10.0.i/24
		largeIfaces[i] = netip.MustParseAddr(fmt.Sprintf("10.0.%d.%d", (i/250)+1, (i%250)+1))
	}
	gotCapped, errCapped := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")}},
		Interfaces: largeIfaces,
	})
	if errCapped == nil || gotCapped != nil {
		t.Fatalf("expected explicit overflow refusal, got %v, %v", gotCapped, errCapped)
	}
}

// 12. DNS overrides: syntax validation and transport scoping.
func TestDNSOverrides(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
		{Transport: endpoints.TransportInternode, Endpoint: ap("0.0.0.0:7947")},
	}

	// Subcase A: Valid DNS overrides with trailing dot handling and case normalization
	gotA, errA := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
		Overrides: []endpoints.Override{
			{Host: "Node-1.Bee.Corp."},
		},
	})
	if errA != nil {
		t.Fatalf("unexpected error for valid DNS: %v", errA)
	}
	if len(gotA) != 2 {
		t.Fatalf("expected 2 candidates, got %d", len(gotA))
	}
	if gotA[0].Host != "node-1.bee.corp" {
		t.Errorf("expected normalized lowercase host node-1.bee.corp, got %s", gotA[0].Host)
	}

	// Subcase B: Transport-scoped override
	gotB, errB := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
		Overrides: []endpoints.Override{
			{Transport: endpoints.TransportInternode, Host: "internode.bee.corp"},
		},
	})
	if errB != nil {
		t.Fatalf("unexpected error for transport-scoped override: %v", errB)
	}
	if len(gotB) != 1 {
		t.Fatalf("expected 1 internode candidate, got %d", len(gotB))
	}
	if gotB[0].Transport != endpoints.TransportInternode || gotB[0].Port != 7947 {
		t.Errorf("expected internode port 7947, got %+v", gotB[0])
	}

	// Subcase C: Malformed DNS names
	badDNS := []string{
		"-starts-with-hyphen.com",
		"ends-with-hyphen-.com",
		"empty..label.com",
		"has space.com",
		"has_underscore.com",
		"192.168.1.999", // not IP, numeric TLD
		"http://example.com",
	}
	for _, bad := range badDNS {
		_, errBad := endpoints.Select(endpoints.Params{
			Mode:      endpoints.ModeExport,
			Listeners: listeners,
			Overrides: []endpoints.Override{{Host: bad}},
		})
		if errBad == nil {
			t.Errorf("expected error for malformed DNS %q, got nil", bad)
		}
	}

	// Subcase D: Localhost override rejected in export mode
	_, errLocal := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
		Overrides: []endpoints.Override{{Host: "localhost"}},
	})
	if errLocal == nil {
		t.Errorf("expected error for localhost override in export mode, got nil")
	}
}

// 13. IPv4-mapped IPv6 handling: ensure ::ffff:192.168.1.1 is cleanly unmapped.
func TestIPv4MappedIPv6(t *testing.T) {
	// Listener using IPv4-mapped IPv6
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("[::ffff:192.168.1.50]:7946")},
	}

	got, err := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(got) != 1 {
		t.Fatalf("expected 1 candidate, got %d", len(got))
	}
	if got[0].Host != "192.168.1.50" {
		t.Errorf("expected unmapped IPv4 host 192.168.1.50, got %s", got[0].Host)
	}
	if got[0].Endpoint() != "192.168.1.50:7946" {
		t.Errorf("expected 192.168.1.50:7946, got %s", got[0].Endpoint())
	}

	// IPv4-mapped loopback in export mode must be excluded
	_, errLoop := endpoints.Select(endpoints.Params{
		Mode: endpoints.ModeExport,
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: ap("[::ffff:127.0.0.1]:7946")},
		},
	})
	if errLoop == nil {
		t.Fatalf("expected error for IPv4-mapped loopback in export mode, got nil")
	}
}

// 14. Deterministic ordering: verify candidate ordering is strictly deterministic.
func TestDeterministicOrdering(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportInternode, Endpoint: ap("0.0.0.0:7947")},
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
	}
	interfaces := []netip.Addr{
		addr("192.168.1.50"),
		addr("100.70.10.28"),
		addr("10.0.0.1"),
	}
	overrides := []endpoints.Override{
		{Host: "seed.example.com"},
	}

	// Run 1
	got1, err1 := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listeners,
		Interfaces: interfaces,
		Overrides:  overrides,
	})
	if err1 != nil {
		t.Fatalf("run 1 failed: %v", err1)
	}

	// Run 2 with reversed input orders
	slices.Reverse(interfaces)
	slices.Reverse(listeners)
	got2, err2 := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listeners,
		Interfaces: interfaces,
		Overrides:  overrides,
	})
	if err2 != nil {
		t.Fatalf("run 2 failed: %v", err2)
	}

	if len(got1) != len(got2) {
		t.Fatalf("length mismatch: %d vs %d", len(got1), len(got2))
	}

	for i := range got1 {
		if got1[i].Transport != got2[i].Transport ||
			got1[i].Endpoint() != got2[i].Endpoint() {
			t.Errorf("order mismatch at %d: %+v vs %+v", i, got1[i], got2[i])
		}
	}

	// Verify category ordering for gossip:
	// 1. Tier 1: DNS override seed.example.com:7946
	// 2. Tier 2: Overlay 100.70.10.28:7946
	// 3. Tier 4: Private LAN 10.0.0.1:7946
	// 4. Tier 4: Private LAN 192.168.1.50:7946
	expectedOrderPrefix := []string{
		"seed.example.com:7946",
		"100.70.10.28:7946",
		"10.0.0.1:7946",
		"192.168.1.50:7946",
	}
	for i, exp := range expectedOrderPrefix {
		if got1[i].Endpoint() != exp {
			t.Errorf("at index %d expected %s, got %s", i, exp, got1[i].Endpoint())
		}
	}
}

// 15. Candidate methods: AddrPort, IsIP, IsDNS, Endpoint, String.
func TestCandidateMethods(t *testing.T) {
	// IP Candidate
	cIP := endpoints.Candidate{
		Transport: endpoints.TransportGossip,
		Host:      "2001:db8::1",
		Port:      7946,
		Addr:      addr("2001:db8::1"),
	}
	if !cIP.IsIP() || cIP.IsDNS() {
		t.Errorf("expected cIP to be IP, not DNS")
	}
	apGot, ok := cIP.AddrPort()
	if !ok || apGot != ap("[2001:db8::1]:7946") {
		t.Errorf("expected [2001:db8::1]:7946, got %v (%v)", apGot, ok)
	}
	if cIP.Endpoint() != "[2001:db8::1]:7946" || cIP.String() != "[2001:db8::1]:7946" {
		t.Errorf("expected [2001:db8::1]:7946, got %q", cIP.Endpoint())
	}

	// DNS Candidate
	cDNS := endpoints.Candidate{
		Transport: endpoints.TransportInternode,
		Host:      "seed.example.com",
		Port:      7947,
	}
	if cDNS.IsIP() || !cDNS.IsDNS() {
		t.Errorf("expected cDNS to be DNS, not IP")
	}
	_, okDNS := cDNS.AddrPort()
	if okDNS {
		t.Errorf("expected AddrPort to return false for DNS candidate")
	}
	if cDNS.Endpoint() != "seed.example.com:7947" || cDNS.String() != "seed.example.com:7947" {
		t.Errorf("expected seed.example.com:7947, got %q", cDNS.Endpoint())
	}
}

// 16. Bracketed IPv6 override with and without port.
func TestBracketedIPv6Override(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportInternode, Endpoint: ap("[::]:7947")},
	}

	// Subcase A: Bracketed IPv6 without port
	gotA, errA := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
		Overrides: []endpoints.Override{{Host: "[2001:db8::5]"}},
	})
	if errA != nil {
		t.Fatalf("unexpected error: %v", errA)
	}
	if len(gotA) != 1 || gotA[0].Endpoint() != "[2001:db8::5]:7947" {
		t.Fatalf("expected [2001:db8::5]:7947, got %+v", gotA)
	}

	// Subcase B: Bracketed IPv6 with matching port
	gotB, errB := endpoints.Select(endpoints.Params{
		Mode:      endpoints.ModeExport,
		Listeners: listeners,
		Overrides: []endpoints.Override{{Host: "[2001:db8::5]:7947"}},
	})
	if errB != nil {
		t.Fatalf("unexpected error: %v", errB)
	}
	if len(gotB) != 1 || gotB[0].Endpoint() != "[2001:db8::5]:7947" {
		t.Fatalf("expected [2001:db8::5]:7947, got %+v", gotB)
	}
}

// 17. Link-local addresses in interface list are excluded from candidate generation.
func TestLinkLocalInterfaceAddressesExcluded(t *testing.T) {
	listeners := []endpoints.Listener{
		{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
	}
	// Interface list with only link-local addresses
	interfaces := []netip.Addr{
		addr("169.254.1.1"),
		addr("169.254.169.254"),
	}

	_, err := endpoints.Select(endpoints.Params{
		Mode:       endpoints.ModeExport,
		Listeners:  listeners,
		Interfaces: interfaces,
	})
	if err == nil {
		t.Fatalf("expected error when only link-local interfaces available, got nil")
	}
	if !errors.Is(err, endpoints.ErrNoExportableEndpoints) {
		t.Errorf("expected ErrNoExportableEndpoints, got %v", err)
	}
}

// 18. Helper constructors and basic bounds.
func TestHelpersAndBounds(t *testing.T) {
	// Empty listeners
	_, errNoL := endpoints.Select(endpoints.Params{})
	if !errors.Is(errNoL, endpoints.ErrNoListeners) {
		t.Errorf("expected ErrNoListeners, got %v", errNoL)
	}

	// Too many overrides (> MaxOverrides = 32)
	manyOv := make([]endpoints.Override, endpoints.MaxOverrides+1)
	for i := range manyOv {
		manyOv[i] = endpoints.Override{Host: fmt.Sprintf("node-%d.example.com", i)}
	}
	_, errManyOv := endpoints.Select(endpoints.Params{
		Listeners: []endpoints.Listener{
			{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:7946")},
		},
		Overrides: manyOv,
	})
	if !errors.Is(errManyOv, endpoints.ErrTooManyOverrides) {
		t.Errorf("expected ErrTooManyOverrides, got %v", errManyOv)
	}

	// Test HostOverrides and NewOverride
	ovs := endpoints.HostOverrides("a.example.com", "b.example.com")
	if len(ovs) != 2 || ovs[0].Host != "a.example.com" || ovs[1].Host != "b.example.com" {
		t.Errorf("unexpected HostOverrides output: %+v", ovs)
	}
	ovTyped := endpoints.NewOverride("c.example.com", endpoints.TransportInternode)
	if ovTyped.Host != "c.example.com" || ovTyped.Transport != endpoints.TransportInternode {
		t.Errorf("unexpected NewOverride output: %+v", ovTyped)
	}
}

func TestUnknownModeCannotExportLoopback(t *testing.T) {
	got, err := endpoints.Select(endpoints.Params{Mode: endpoints.Mode(99), Listeners: []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("127.0.0.1:1234")}}})
	if err == nil || got != nil {
		t.Fatalf("unknown mode accepted: %v, %v", got, err)
	}
}

func TestOverrideUsesSameAddressRulesAsListener(t *testing.T) {
	for _, mode := range []endpoints.Mode{endpoints.ModeExport, endpoints.ModeLocalOnly} {
		for _, host := range []string{"169.254.1.2", "fe80::1", "255.255.255.255", "::ffff:100.70.10.28%eth0"} {
			t.Run(fmt.Sprintf("%d/%s", mode, host), func(t *testing.T) {
				got, err := endpoints.Select(endpoints.Params{Mode: mode, Listeners: []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:1234")}}, Overrides: []endpoints.Override{{Host: host}}})
				if err == nil || got != nil {
					t.Fatalf("ineligible override accepted: %v, %v", got, err)
				}
			})
		}
	}
}

func TestMappedListenerCannotHideZone(t *testing.T) {
	got, err := endpoints.Select(endpoints.Params{Listeners: []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("[::ffff:100.70.10.28%eth0]:1234")}}})
	if err == nil || got != nil {
		t.Fatalf("scoped mapped listener accepted: %v, %v", got, err)
	}
}

func TestScopedInterfaceDoesNotHideUsableOverlay(t *testing.T) {
	got, err := endpoints.Select(endpoints.Params{
		Listeners:  []endpoints.Listener{{Transport: endpoints.TransportGossip, Endpoint: ap("0.0.0.0:32123")}},
		Interfaces: []netip.Addr{netip.MustParseAddr("fe80::1%eth0"), netip.MustParseAddr("100.70.10.28")},
	})
	if err != nil || len(got) != 1 || got[0].Endpoint() != "100.70.10.28:32123" {
		t.Fatalf("usable overlay lost: %v, %v", got, err)
	}
}
