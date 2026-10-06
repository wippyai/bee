// SPDX-License-Identifier: MIT

package invite

import (
	"context"
	"crypto/ed25519"
	"net"
	"testing"
)

func probeListener(t *testing.T, joiner ed25519.PrivateKey) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- ServeProbe(ctx, listener, joiner) }()
	t.Cleanup(func() {
		cancel()
		if err := <-done; err != nil {
			t.Error(err)
		}
	})
	return listener.Addr().(*net.TCPAddr).Port
}

// The hive node reaches the joiner on the address that answers.
func TestReachFindsTheJoinerAddressTheHiveNodeCanDial(t *testing.T) {
	hive, joiner := identity(t), identity(t)
	port := probeListener(t, joiner)
	address, err := Reach(context.Background(), []string{"127.0.0.1"}, port, joiner.Public().(ed25519.PublicKey), hive)
	if err != nil || address.String() != "127.0.0.1" {
		t.Fatalf("reach = %v, %v", address, err)
	}
}

// A listener that is not the joiner never counts as its address.
func TestReachRefusesAListenerThatIsNotTheJoiner(t *testing.T) {
	hive, joiner, impostor := identity(t), identity(t), identity(t)
	port := probeListener(t, impostor)
	if _, err := Reach(context.Background(), []string{"127.0.0.1"}, port, joiner.Public().(ed25519.PublicKey), hive); err == nil {
		t.Fatal("reached an impostor")
	}
}
