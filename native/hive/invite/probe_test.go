// SPDX-License-Identifier: MIT

package invite

import (
	"context"
	"crypto/ed25519"
	"net"
	"net/netip"
	"testing"
	"time"
)

func probeListener(t *testing.T, joiner ed25519.PrivateKey, fingerprint string) (int, chan netip.Addr) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	reached := make(chan netip.Addr, 1)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- ServeProbe(ctx, listener, joiner, fingerprint, reached) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	})
	return listener.Addr().(*net.TCPAddr).Port, reached
}

// The hive node reaches the joiner on the address that answers, and the joiner
// learns which of its addresses was reached.
func TestReachFindsTheJoinerAddressTheHiveNodeCanDial(t *testing.T) {
	hive, joiner := identity(t), identity(t)
	port, reached := probeListener(t, joiner, Fingerprint(hive.Public().(ed25519.PublicKey)))
	address, err := Reach(context.Background(), []string{"127.0.0.1"}, port, joiner.Public().(ed25519.PublicKey), hive)
	if err != nil || address.String() != "127.0.0.1" {
		t.Fatalf("reach = %v, %v", address, err)
	}
	select {
	case local := <-reached:
		if local.String() != "127.0.0.1" {
			t.Fatalf("joiner saw the probe on %v", local)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("joiner did not see the probe")
	}
}

// A listener that is not the joiner never counts as its address.
func TestReachRefusesAListenerThatIsNotTheJoiner(t *testing.T) {
	hive, joiner, impostor := identity(t), identity(t), identity(t)
	port, _ := probeListener(t, impostor, Fingerprint(hive.Public().(ed25519.PublicKey)))
	if _, err := Reach(context.Background(), []string{"127.0.0.1"}, port, joiner.Public().(ed25519.PublicKey), hive); err == nil {
		t.Fatal("reached an impostor")
	}
}

// A probe from a peer other than the invite's hive node is not reported.
func TestProbeFromAnotherPeerIsNotReported(t *testing.T) {
	hive, joiner, stranger := identity(t), identity(t), identity(t)
	port, reached := probeListener(t, joiner, Fingerprint(hive.Public().(ed25519.PublicKey)))
	if _, err := Reach(context.Background(), []string{"127.0.0.1"}, port, joiner.Public().(ed25519.PublicKey), stranger); err != nil {
		t.Fatal(err)
	}
	select {
	case local := <-reached:
		t.Fatalf("reported a probe from a stranger: %v", local)
	case <-time.After(300 * time.Millisecond):
	}
}
