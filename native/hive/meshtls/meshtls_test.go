// SPDX-License-Identifier: MIT

package meshtls

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net"
	"net/netip"
	"testing"
	"time"
)

func authority(t *testing.T, now time.Time) (Authority, []byte) {
	t.Helper()
	document, err := NewAuthority(now)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeAuthority(document, now)
	if err != nil {
		t.Fatal(err)
	}
	return decoded, document
}

func credential(t *testing.T, issuer Authority, now time.Time) ([]byte, ed25519.PublicKey) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := issuer.Issue(public, []netip.Addr{netip.MustParseAddr("192.0.2.7")}, now)
	if err != nil {
		t.Fatal(err)
	}
	document, err := Credential(leaf, private)
	if err != nil {
		t.Fatal(err)
	}
	return document, public
}

// A hive node signs the joiner's leaf; with pools merged as the join does, the
// two nodes complete mutual TLS in both directions under the runtime's rules.
func TestJoinedLeafCompletesMutualTLSWithTheHiveNode(t *testing.T) {
	now := time.Now()
	hive, _ := authority(t, now)
	joiner, _ := authority(t, now)
	hiveCredential, _ := credential(t, hive, now)
	joinedCredential, _ := credential(t, hive, now)
	hivePool, err := Pool(hive.Certificate())
	if err != nil {
		t.Fatal(err)
	}
	joinedPool, err := Pool(joiner.Certificate(), hivePool)
	if err != nil {
		t.Fatal(err)
	}
	if roots, err := Authorities(joinedPool); err != nil || len(roots) != 2 {
		t.Fatalf("joined pool = %d roots, %v", len(roots), err)
	}
	handshake(t, hiveCredential, hivePool, joinedCredential, joinedPool)
	handshake(t, joinedCredential, joinedPool, hiveCredential, hivePool)
}

func config(t *testing.T, credential, pool []byte) *tls.Config {
	t.Helper()
	pair, err := tls.X509KeyPair(credential, credential)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pool) {
		t.Fatal("pool has no certificates")
	}
	return &tls.Config{Certificates: []tls.Certificate{pair}, RootCAs: roots, ClientCAs: roots,
		ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS12}
}

func handshake(t *testing.T, serverCredential, serverPool, clientCredential, clientPool []byte) {
	t.Helper()
	listener, err := tls.Listen("tcp", "127.0.0.1:0", config(t, serverCredential, serverPool))
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
		accepted <- connection.(*tls.Conn).Handshake()
	}()
	dialer := &tls.Dialer{Config: config(t, clientCredential, clientPool)}
	connection, err := dialer.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = connection.Close()
	if err := <-accepted; err != nil {
		t.Fatal(err)
	}
}

func TestVerifyBindsTheLeafToItsKeyAndPool(t *testing.T) {
	now := time.Now()
	hive, _ := authority(t, now)
	other, _ := authority(t, now)
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := hive.Issue(public, []netip.Addr{netip.MustParseAddr("::1")}, now)
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(leaf, hive.Certificate(), public, now); err != nil {
		t.Fatal(err)
	}
	stranger, _, _ := ed25519.GenerateKey(rand.Reader)
	if err := Verify(leaf, hive.Certificate(), stranger, now); !errors.Is(err, ErrCredentials) {
		t.Fatalf("leaf verified for another key: %v", err)
	}
	if err := Verify(leaf, other.Certificate(), public, now); !errors.Is(err, ErrCredentials) {
		t.Fatalf("leaf verified against an unrelated authority: %v", err)
	}
	if err := Verify(leaf, hive.Certificate(), public, now.Add(LeafLifetime+time.Hour)); !errors.Is(err, ErrCredentials) {
		t.Fatalf("expired leaf verified: %v", err)
	}
	certificate, err := x509.ParseCertificate(mustBlock(t, leaf))
	if err != nil {
		t.Fatal(err)
	}
	if len(certificate.IPAddresses) != 2 || !certificate.IPAddresses[0].Equal(net.ParseIP("127.0.0.1")) || !certificate.IPAddresses[1].Equal(net.ParseIP("::1")) {
		t.Fatalf("leaf addresses = %v", certificate.IPAddresses)
	}
	if _, err := hive.Issue(public, []netip.Addr{netip.MustParseAddr("0.0.0.0")}, now); !errors.Is(err, ErrCredentials) {
		t.Fatalf("unspecified address issued: %v", err)
	}
}

func mustBlock(t *testing.T, document []byte) []byte {
	t.Helper()
	block, _ := pem.Decode(document)
	if block == nil {
		t.Fatal("document has no PEM block")
	}
	return block.Bytes
}

func TestAuthorityRefusesMalformedAndExpiredDocuments(t *testing.T) {
	now := time.Now()
	hive, document := authority(t, now)
	if _, err := DecodeAuthority(document, now.Add(authorityLifetime+time.Hour)); !errors.Is(err, ErrCredentials) {
		t.Fatalf("expired authority decoded: %v", err)
	}
	if _, err := DecodeAuthority(hive.Certificate(), now); !errors.Is(err, ErrCredentials) {
		t.Fatalf("authority without key decoded: %v", err)
	}
	leafCredential, _ := credential(t, hive, now)
	if _, err := Authorities(leafCredential); !errors.Is(err, ErrCredentials) {
		t.Fatalf("leaf accepted as an authority: %v", err)
	}
	merged, err := Pool(hive.Certificate(), hive.Certificate())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(merged, hive.Certificate()) {
		t.Fatal("pool kept a duplicate authority")
	}
	if _, err := Pool(nil); !errors.Is(err, ErrCredentials) {
		t.Fatalf("empty pool accepted: %v", err)
	}
	selected := Config("/state/hive")
	if !selected.Enabled || selected.CertFile != "/state/hive/mesh.pem" || selected.KeyFile != selected.CertFile || selected.CAFile != "/state/hive/mesh-authorities.pem" {
		t.Fatalf("config = %#v", selected)
	}
}
