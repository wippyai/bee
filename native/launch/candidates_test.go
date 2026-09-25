// SPDX-License-Identifier: MIT

package launch

import (
	"net/netip"
	"testing"

	"github.com/wippyai/bee/native/hive/invite"
)

func TestJoinCandidatesPreferExplicitAndTailnetThenInterfaces(t *testing.T) {
	primary := netip.MustParseAddrPort("127.0.0.1:4200")
	assigned := []interfaceAddress{
		{name: "docker0", address: netip.MustParseAddr("172.17.0.1")},
		{name: "eth0", address: netip.MustParseAddr("192.168.2.4")},
		{name: "tailscale0", address: netip.MustParseAddr("100.70.10.28")},
		{name: "eth0", address: netip.MustParseAddr("fe80::1")},
		{name: "eth0", address: netip.MustParseAddr("2001:db8::4")},
	}
	got := selectJoinCandidates(primary, assigned, []netip.Addr{netip.MustParseAddr("100.70.10.28")}, "bee.example.ts.net", []netip.Addr{netip.MustParseAddr("203.0.113.4")})
	want := []invite.Candidate{
		{Kind: "explicit", Scope: "external", Endpoint: "203.0.113.4:4200"},
		{Kind: "tailnet", Scope: "tailnet", Endpoint: "100.70.10.28:4200"},
		{Kind: "magicdns", Scope: "tailnet", Endpoint: "bee.example.ts.net:4200"},
		{Kind: "interface", Scope: "lan", Endpoint: "192.168.2.4:4200"},
		{Kind: "interface", Scope: "lan", Endpoint: "[2001:db8::4]:4200"},
		{Kind: "interface", Scope: "vm", Endpoint: "172.17.0.1:4200"},
	}
	if len(got) != len(want) {
		t.Fatalf("candidates = %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("candidate %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestJoinCandidatesBoundAndDeduplicateAcrossInterfaces(t *testing.T) {
	primary := netip.MustParseAddrPort("192.168.0.1:4200")
	var assigned []interfaceAddress
	for i := 1; i <= 20; i++ {
		assigned = append(assigned, interfaceAddress{name: "eth0", address: netip.AddrFrom4([4]byte{10, 0, 0, byte(i)})})
	}
	got := selectJoinCandidates(primary, assigned, nil, "", nil)
	if len(got) != invite.MaxCandidates {
		t.Fatalf("candidate count = %d", len(got))
	}
	for _, candidate := range got {
		if candidate.Endpoint == primary.String() {
			t.Fatal("primary duplicated")
		}
	}
}

func TestMeshCertificateCoversCandidateIPAddresses(t *testing.T) {
	selected := netip.MustParseAddr("127.0.0.1")
	assigned := []interfaceAddress{{name: "eth0", address: netip.MustParseAddr("192.168.1.4")}, {name: "tailscale0", address: netip.MustParseAddr("fd7a:115c:a1e0::4")}}
	explicit := []netip.Addr{netip.MustParseAddr("203.0.113.9")}
	got := meshCertificateAddresses(selected, assigned, explicit)
	want := []netip.Addr{selected, explicit[0], assigned[0].address, assigned[1].address}
	if len(got) != len(want) {
		t.Fatalf("addresses = %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("address %d = %s, want %s", i, got[i], want[i])
		}
	}
}
