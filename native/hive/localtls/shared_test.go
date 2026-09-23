//go:build meshclient

// SPDX-License-Identifier: MIT
package localtls

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func privateTemp(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	return directory
}

func tlsConfig(t *testing.T, credentials Credentials, server bool) *tls.Config {
	t.Helper()
	pair, err := tls.LoadX509KeyPair(credentials.TLS.CertFile, credentials.TLS.KeyFile)
	if err != nil {
		t.Fatal(err)
	}
	pem, err := os.ReadFile(credentials.TLS.CAFile)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		t.Fatal("no certificate roots")
	}
	result := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{pair}, RootCAs: pool}
	if server {
		result.ClientCAs = pool
		result.ClientAuth = tls.RequireAndVerifyClientCert
	}
	return result
}

func TestSharedAuthorityConnectsDistinctExecutions(t *testing.T) {
	ctx := context.Background()
	authority := privateTemp(t)
	first, second := privateTemp(t), privateTemp(t)
	expires := time.Now().Add(time.Hour)
	a, err := PrepareShared(ctx, first, strings.Repeat("a", 32), expires, authority)
	if err != nil {
		t.Fatal(err)
	}
	b, err := PrepareShared(ctx, second, strings.Repeat("b", 32), expires, authority)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Load(ctx, first, strings.Repeat("a", 32)); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(a.TLS.CertFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(first, document(strings.Repeat("b", 32))), data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(ctx, first, strings.Repeat("b", 32)); err != ErrExecution {
		t.Fatal("execution fence lost", err)
	}
	ca, cb := tlsConfig(t, a, true), tlsConfig(t, b, false)
	if string(ca.Certificates[0].Certificate[0]) == string(cb.Certificates[0].Certificate[0]) {
		t.Fatal("nodes share leaf identity")
	}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", ca)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan error, 1)
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			accepted <- err
			return
		}
		defer connection.Close()
		_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
		accepted <- connection.(*tls.Conn).Handshake()
	}()
	dialer := &tls.Dialer{Config: cb}
	deadline, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	connection, err := dialer.DialContext(deadline, "tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	connection.Close()
	if err := <-accepted; err != nil {
		t.Fatal(err)
	}
	other, err := PrepareShared(ctx, privateTemp(t), strings.Repeat("c", 32), expires, privateTemp(t))
	if err != nil {
		t.Fatal(err)
	}
	foreign := tlsConfig(t, other, false)
	leaf, err := x509.ParseCertificate(ca.Certificates[0].Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: foreign.RootCAs, DNSName: "127.0.0.1"}); err == nil {
		t.Fatal("unrelated Hive trusted")
	}
}

func TestSharedAuthorityCapsExpiryAndPreservesMalformedState(t *testing.T) {
	ctx := context.Background()
	authority := privateTemp(t)
	now := time.Now().Truncate(time.Second)
	a, err := prepareShared(ctx, privateTemp(t), strings.Repeat("a", 32), now.Add(time.Hour), authority, now)
	if err != nil {
		t.Fatal(err)
	}
	later := now.Add(maxLifetime - time.Hour)
	b, err := prepareShared(ctx, privateTemp(t), strings.Repeat("b", 32), later.Add(2*time.Hour), authority, later)
	if err != nil {
		t.Fatal(err)
	}
	if !b.ExpiresAt.Equal(now.Add(maxLifetime)) || !a.ExpiresAt.Equal(now.Add(time.Hour)) {
		t.Fatal(a.ExpiresAt, b.ExpiresAt)
	}
	path := filepath.Join(authority, "authority.pem")
	if err := os.WriteFile(path, []byte("malformed"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareShared(ctx, privateTemp(t), strings.Repeat("c", 32), now.Add(time.Hour), authority, now); err == nil {
		t.Fatal("malformed authority repaired")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "malformed" {
		t.Fatal("authority changed", err)
	}
}

func TestSharedAuthorityConcurrentIssuanceAndExpiryRotation(t *testing.T) {
	ctx := context.Background()
	directory := privateTemp(t)
	now := time.Now().Truncate(time.Second)
	type result struct {
		credentials Credentials
		err         error
	}
	results := make(chan result, 4)
	for _, id := range []string{"1", "2", "3", "4"} {
		leafDir := privateTemp(t)
		go func(identity, leafDirectory string) {
			credentials, err := prepareShared(ctx, leafDirectory, strings.Repeat(identity, 32), now.Add(time.Hour), directory, now)
			results <- result{credentials, err}
		}(id, leafDir)
	}
	var root []byte
	for range 4 {
		issued := <-results
		if issued.err != nil {
			t.Fatal(issued.err)
		}
		pair, err := tls.LoadX509KeyPair(issued.credentials.TLS.CertFile, issued.credentials.TLS.KeyFile)
		if err != nil {
			t.Fatal(err)
		}
		if len(pair.Certificate) != 2 {
			t.Fatal("missing issuer")
		}
		if root == nil {
			root = pair.Certificate[1]
		} else if string(root) != string(pair.Certificate[1]) {
			t.Fatal("concurrent issuance split the Hive authority")
		}
	}
	later := now.Add(maxLifetime + time.Second)
	rotated, err := prepareShared(ctx, privateTemp(t), strings.Repeat("5", 32), later.Add(time.Hour), directory, later)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.LoadX509KeyPair(rotated.TLS.CertFile, rotated.TLS.KeyFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(root) == string(pair.Certificate[1]) {
		t.Fatal("expired authority reused")
	}
}
