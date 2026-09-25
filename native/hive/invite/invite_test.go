// SPDX-License-Identifier: MIT

package invite

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"net"
	"net/netip"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
)

func identity(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return private
}

func sample(address netip.AddrPort, key ed25519.PrivateKey) Invite {
	return Invite{ID: strings.Repeat("a", 32), Secret: strings.Repeat("b", 64), Address: address,
		Node: "bee-owner-0123456789abcdef", Fingerprint: Fingerprint(key.Public().(ed25519.PublicKey))}
}

func TestInviteLineRoundTripsExactly(t *testing.T) {
	for _, address := range []string{"127.0.0.1:40123", "[::1]:40123", "192.0.2.10:7000"} {
		original := sample(netip.MustParseAddrPort(address), identity(t))
		line := original.String()
		if strings.ContainsAny(line, " \n\t") || !strings.HasPrefix(line, "bee-hive://") {
			t.Fatalf("invite is not one pasteable line: %q", line)
		}
		parsed, err := Parse(" " + line + "\n")
		if err != nil {
			t.Fatalf("parse %q: %v", line, err)
		}
		if !reflect.DeepEqual(parsed, original) {
			t.Fatalf("parsed %+v, want %+v", parsed, original)
		}
	}
}

func TestInviteCarriesBoundedTypedCandidates(t *testing.T) {
	item := sample(netip.MustParseAddrPort("127.0.0.1:40123"), identity(t))
	item.Candidates = []Candidate{
		{Kind: "interface", Scope: "lan", Endpoint: "192.168.1.4:40123"},
		{Kind: "tailnet", Scope: "tailnet", Endpoint: "[fd7a:115c:a1e0::1]:40123"},
		{Kind: "magicdns", Scope: "tailnet", Endpoint: "bee.tailnet.ts.net:40123"},
	}
	line := item.String()
	parsed, err := Parse(line)
	if err != nil || !reflect.DeepEqual(parsed, item) || len(line) > 1024 {
		t.Fatalf("candidate round trip = %+v, %v, bytes %d", parsed, err, len(line))
	}
	item.Candidates = append(item.Candidates, item.Candidates...)
	item.Candidates = append(item.Candidates, item.Candidates...)
	if _, err := Parse(item.String()); !errors.Is(err, ErrInvite) {
		t.Fatalf("accepted too many candidates: %v", err)
	}
}

func TestDialTriesCandidatesAndReportsEachFailure(t *testing.T) {
	hive := identity(t)
	address := listen(t, hive, func(context.Context, ed25519.PublicKey, Request) (Admission, *Refused) {
		return Admission{Node: "bee-owner-0123456789abcdef", Gossip: "127.0.0.1:1"}, nil
	})
	item := sample(netip.MustParseAddrPort("127.0.0.1:1"), hive)
	item.Candidates = []Candidate{{Kind: "interface", Scope: "host", Endpoint: address.String()}}
	_, _, selected, err := DialCandidates(context.Background(), item, identity(t), Request{Node: "bee-owner-joiner"})
	if err != nil || selected.Endpoint != address.String() {
		t.Fatalf("selected = %+v, %v", selected, err)
	}
	item.Candidates[0].Endpoint = "127.0.0.1:2"
	_, _, _, err = DialCandidates(context.Background(), item, identity(t), Request{Node: "bee-owner-joiner"})
	if err == nil || !strings.Contains(err.Error(), "127.0.0.1:1") || !strings.Contains(err.Error(), "127.0.0.1:2") {
		t.Fatalf("missing per-candidate errors: %v", err)
	}
}

func TestDialAcrossASecondLocalInterface(t *testing.T) {
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	var external netip.Addr
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			t.Fatal(err)
		}
		for _, value := range addresses {
			if network, ok := value.(*net.IPNet); ok {
				if address, ok := netip.AddrFromSlice(network.IP); ok && address.Unmap().Is4() && address.IsGlobalUnicast() {
					external = address.Unmap()
					break
				}
			}
		}
		if external.IsValid() {
			break
		}
	}
	if !external.IsValid() {
		t.Skip("no second routable interface")
	}
	hive := identity(t)
	listener, err := net.Listen("tcp", netip.AddrPortFrom(external, 0).String())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- Serve(ctx, listener, hive, func(context.Context, ed25519.PublicKey, Request) (Admission, *Refused) {
			return Admission{Node: "bee-owner-0123456789abcdef", Gossip: "127.0.0.1:1"}, nil
		})
	}()
	defer func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	}()
	port := listener.Addr().(*net.TCPAddr).Port
	item := sample(netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(port)), hive)
	item.Candidates = []Candidate{{Kind: "interface", Scope: "lan", Endpoint: netip.AddrPortFrom(external, uint16(port)).String()}}
	_, _, selected, err := DialCandidates(context.Background(), item, identity(t), Request{Node: "bee-owner-joiner"})
	if err != nil || selected.Endpoint != item.Candidates[0].Endpoint {
		t.Fatalf("second interface path = %+v, %v", selected, err)
	}
}

func TestParseRefusesMalformedInvites(t *testing.T) {
	good := sample(netip.MustParseAddrPort("127.0.0.1:40123"), identity(t)).String()
	for _, line := range []string{
		"",
		strings.Replace(good, "bee-hive://", "https://", 1),
		strings.Replace(good, strings.Repeat("a", 32), strings.Repeat("A", 32), 1),
		strings.Replace(good, strings.Repeat("b", 64), strings.Repeat("b", 63), 1),
		strings.Replace(good, "127.0.0.1:40123", "127.0.0.1:0", 1),
		strings.Replace(good, "127.0.0.1:40123", "0.0.0.0:40123", 1),
		strings.Replace(good, "127.0.0.1:40123", "example.test:40123", 1),
		strings.Replace(good, "/bee-owner-", "/bee owner-", 1),
		good + "&extra=1",
		good + "#fragment",
		good[:len(good)-1],
	} {
		if _, err := Parse(line); !errors.Is(err, ErrInvite) {
			t.Fatalf("accepted %q: %v", line, err)
		}
	}
}

func listen(t *testing.T, hive ed25519.PrivateKey, handler Handler) netip.AddrPort {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, listener, hive, handler) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	})
	return netip.MustParseAddrPort(listener.Addr().String())
}

// The joiner proves its identity key, discloses the secret only to the pinned
// hive node and receives the hive node's admission.
func TestDialRedeemsAgainstThePinnedHiveNode(t *testing.T) {
	hive, joiner := identity(t), identity(t)
	var seen atomic.Pointer[Request]
	var peer atomic.Pointer[ed25519.PublicKey]
	address := listen(t, hive, func(_ context.Context, key ed25519.PublicKey, request Request) (Admission, *Refused) {
		seen.Store(&request)
		peer.Store(&key)
		return Admission{Node: "bee-owner-0123456789abcdef", Gossip: "127.0.0.1:1", Secret: "c2VjcmV0", Certificate: "leaf", Authorities: "pool"}, nil
	})
	invite := sample(address, hive)
	admission, pinned, err := Dial(context.Background(), invite, joiner, Request{Node: "bee-owner-joiner", Addresses: []string{"127.0.0.1"}, Key: "a2V5"})
	if err != nil {
		t.Fatal(err)
	}
	if !pinned.Equal(hive.Public()) {
		t.Fatal("dial did not return the pinned hive key")
	}
	if admission.Gossip != "127.0.0.1:1" || admission.Version != Version || admission.Certificate != "leaf" {
		t.Fatalf("admission = %+v", admission)
	}
	request := seen.Load()
	if request == nil || request.Invite != invite.ID || request.Secret != invite.Secret || request.Node != "bee-owner-joiner" || request.Key != "a2V5" {
		t.Fatalf("hive node saw %+v", request)
	}
	if key := peer.Load(); key == nil || !key.Equal(joiner.Public()) {
		t.Fatal("hive node did not see the joiner's identity key")
	}
}

// A listener whose identity differs from the invite fingerprint never receives
// the secret.
func TestDialRefusesAnUnpinnedHiveNode(t *testing.T) {
	impostor, expected := identity(t), identity(t)
	var called atomic.Bool
	address := listen(t, impostor, func(context.Context, ed25519.PublicKey, Request) (Admission, *Refused) {
		called.Store(true)
		return Admission{}, nil
	})
	_, _, err := Dial(context.Background(), sample(address, expected), identity(t), Request{Node: "bee-owner-joiner"})
	if err == nil || !strings.Contains(err.Error(), "does not match the invite") {
		t.Fatalf("dial = %v", err)
	}
	if called.Load() {
		t.Fatal("an unpinned listener received the invite secret")
	}
}

func TestDialReportsTheHiveNodeRefusal(t *testing.T) {
	hive := identity(t)
	address := listen(t, hive, func(context.Context, ed25519.PublicKey, Request) (Admission, *Refused) {
		return Admission{}, &Refused{Code: "CONFLICT", Message: "invite was already used"}
	})
	_, _, err := Dial(context.Background(), sample(address, hive), identity(t), Request{Node: "bee-owner-joiner"})
	var refused *Refused
	if !errors.As(err, &refused) || refused.Code != "CONFLICT" || refused.Message != "invite was already used" {
		t.Fatalf("dial = %v", err)
	}
}

// An admission for another node than the invite names is not accepted.
func TestDialRefusesAnAdmissionForAnotherNode(t *testing.T) {
	hive := identity(t)
	address := listen(t, hive, func(context.Context, ed25519.PublicKey, Request) (Admission, *Refused) {
		return Admission{Node: "bee-owner-elsewhere"}, nil
	})
	if _, _, err := Dial(context.Background(), sample(address, hive), identity(t), Request{Node: "bee-owner-joiner"}); err == nil {
		t.Fatal("accepted an admission for another node")
	}
}
