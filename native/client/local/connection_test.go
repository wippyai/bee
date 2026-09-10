// SPDX-License-Identifier: MIT
package local

import (
	"context"
	"crypto/tls"
	"net"
	"testing"
	"time"
)

func TestCloseDoesNotWaitForTLSCloseNotification(t *testing.T) {
	_, _, _, config, err := generateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	server := tls.Server(left, config)
	client := tls.Client(right, &tls.Config{RootCAs: config.ClientCAs, Certificates: config.Certificates, ServerName: "localhost", MinVersion: tls.VersionTLS13})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	handshaken := make(chan error, 1)
	go func() { handshaken <- server.HandshakeContext(ctx) }()
	if err := client.HandshakeContext(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-handshaken; err != nil {
		t.Fatal(err)
	}
	// The authenticated peer deliberately performs no more reads.
	closed := make(chan struct{})
	go func() { (&connection{server}).Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(500 * time.Millisecond):
		left.Close()
		<-closed
		t.Fatal("detach waited for peer to read a TLS notification")
	}
}
