//go:build meshclient

// SPDX-License-Identifier: MIT

package localtls

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/wippyai/runtime/cluster/internode"
)

const joinedExecution = "2123456789abcdef0123456789abcdef"

type joinedFixtureOptions struct {
	leafNotBefore time.Duration
	leafLifetime  time.Duration
	rootLifetime  time.Duration
	loopbackSAN   bool
	rootNotCA     bool
	otherRoot     bool
	wrongKey      bool
}

func joinedTLSFixture(t *testing.T, options joinedFixtureOptions) internode.ManagerTLSConfig {
	t.Helper()
	now := time.Now().Truncate(time.Second)
	if options.leafLifetime == 0 {
		options.leafLifetime = 45 * 24 * time.Hour
	}
	if options.rootLifetime == 0 {
		options.rootLifetime = 90 * 24 * time.Hour
	}
	rootPublic, rootPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	rootTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Joined Hive test root"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(options.rootLifetime),
		IsCA: !options.rootNotCA, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	if options.rootNotCA {
		rootTemplate.KeyUsage = x509.KeyUsageDigitalSignature
	}
	rootDER, err := x509.CreateCertificate(rand.Reader, rootTemplate, rootTemplate, rootPublic, rootPrivate)
	if err != nil {
		t.Fatal(err)
	}
	rootCert, err := x509.ParseCertificate(rootDER)
	if err != nil {
		t.Fatal(err)
	}
	leafPublic, leafPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "joined hive owner"},
		NotBefore: now.Add(options.leafNotBefore), NotAfter: now.Add(options.leafLifetime),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	if options.loopbackSAN {
		leafTemplate.IPAddresses = []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, rootCert, leafPublic, rootPrivate)
	if err != nil {
		t.Fatal(err)
	}
	keyToWrite := leafPrivate
	if options.wrongKey {
		_, keyToWrite, err = ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(keyToWrite)
	if err != nil {
		t.Fatal(err)
	}
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	caCert := rootDER
	if options.otherRoot {
		otherPublic, otherPrivate, generateErr := ed25519.GenerateKey(rand.Reader)
		if generateErr != nil {
			t.Fatal(generateErr)
		}
		otherTemplateValue := *rootTemplate
		otherTemplate := &otherTemplateValue
		otherTemplate.SerialNumber = big.NewInt(3)
		caCert, err = x509.CreateCertificate(rand.Reader, otherTemplate, otherTemplate, otherPublic, otherPrivate)
		if err != nil {
			t.Fatal(err)
		}
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCert})
	directory := t.TempDir()
	certPath := filepath.Join(directory, "joined-cert.pem")
	keyPath := filepath.Join(directory, "joined-key.pem")
	caPath := filepath.Join(directory, "joined-ca.pem")
	if err := os.WriteFile(certPath, certificatePEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyPath, keyPEM, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(caPath, caPEM, 0600); err != nil {
		t.Fatal(err)
	}
	return internode.ManagerTLSConfig{Enabled: true, CertFile: certPath, KeyFile: keyPath, CAFile: caPath}
}

func TestSnapshotJoinedLoadsExactIdentityAndSupportsMutualTLS(t *testing.T) {
	ctx := context.Background()
	ownerDirectory := privateDir(t)
	source := joinedTLSFixture(t, joinedFixtureOptions{loopbackSAN: true})
	credentials, err := SnapshotJoined(ctx, ownerDirectory, joinedExecution, source)
	if err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(ctx, ownerDirectory, joinedExecution)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.TLS != credentials.TLS || !loaded.ExpiresAt.Equal(credentials.ExpiresAt) {
		t.Fatalf("snapshot/load mismatch: got %#v want %#v", loaded, credentials)
	}
	if credentials.TLS.CertFile != credentials.TLS.KeyFile || credentials.TLS.KeyFile != credentials.TLS.CAFile {
		t.Fatal("joined snapshot did not use the protected combined PEM")
	}
	info, err := os.Stat(credentials.TLS.CertFile)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("snapshot file permissions = %o, want 600", info.Mode().Perm())
	}
	if credentials.ExpiresAt.After(time.Now().Add(maxLifetime)) || !credentials.ExpiresAt.After(time.Now()) {
		t.Fatalf("snapshot expiry is not bounded: %s", credentials.ExpiresAt)
	}
	pair, err := tls.LoadX509KeyPair(credentials.TLS.CertFile, credentials.TLS.KeyFile)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	if leaf.Subject.CommonName != "joined hive owner" {
		t.Fatalf("snapshot changed the joined TLS identity: %q", leaf.Subject.CommonName)
	}
	for _, address := range []string{"127.0.0.1", "::1"} {
		if err := leaf.VerifyHostname(address); err != nil {
			t.Fatalf("snapshot lost loopback SAN %s: %v", address, err)
		}
	}
	clientPool, serverPool := x509.NewCertPool(), x509.NewCertPool()
	data, err := os.ReadFile(credentials.TLS.CAFile)
	if err != nil {
		t.Fatal(err)
	}
	if !clientPool.AppendCertsFromPEM(data) || !serverPool.AppendCertsFromPEM(data) {
		t.Fatal("snapshot omitted the configured CA")
	}
	serverTLS := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{pair}, ClientCAs: serverPool, ClientAuth: tls.RequireAndVerifyClientCert}
	clientTLS := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{pair}, RootCAs: clientPool}
	listener, err := tls.Listen("tcp", "127.0.0.1:0", serverTLS)
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
	deadline, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	connection, err := (&tls.Dialer{Config: clientTLS}).DialContext(deadline, "tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = connection.Close()
	if err := <-accepted; err != nil {
		t.Fatal(err)
	}
}

func TestSnapshotJoinedRejectsInvalidMaterialAndBoundsInputs(t *testing.T) {
	tests := []struct {
		name    string
		options joinedFixtureOptions
	}{
		{name: "mismatched key", options: joinedFixtureOptions{loopbackSAN: true, wrongKey: true}},
		{name: "untrusted authority", options: joinedFixtureOptions{loopbackSAN: true, otherRoot: true}},
		{name: "non CA trust anchor", options: joinedFixtureOptions{loopbackSAN: true, rootNotCA: true}},
		{name: "missing loopback SAN", options: joinedFixtureOptions{}},
		{name: "not yet valid", options: joinedFixtureOptions{loopbackSAN: true, leafNotBefore: time.Hour}},
		{name: "expired", options: joinedFixtureOptions{loopbackSAN: true, leafLifetime: -time.Hour}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			directory := privateDir(t)
			_, err := SnapshotJoined(context.Background(), directory, joinedExecution, joinedTLSFixture(t, test.options))
			if !errors.Is(err, ErrCredentials) {
				t.Fatalf("SnapshotJoined error = %v, want ErrCredentials", err)
			}
			if _, err := os.Stat(filepath.Join(directory, document(joinedExecution))); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("invalid material published a snapshot: %v", err)
			}
		})
	}
	tooLarge := joinedTLSFixture(t, joinedFixtureOptions{loopbackSAN: true})
	large := filepath.Join(t.TempDir(), "oversized-ca.pem")
	if err := os.WriteFile(large, bytes.Repeat([]byte("x"), maxJoinedSourceFileBytes+1), 0600); err != nil {
		t.Fatal(err)
	}
	tooLarge.CAFile = large
	if _, err := SnapshotJoined(context.Background(), privateDir(t), joinedExecution, tooLarge); !errors.Is(err, ErrCredentials) {
		t.Fatalf("oversized source error = %v", err)
	}
}

func TestSnapshotJoinedBindsExecutionAndKeepsFirstIdentity(t *testing.T) {
	ctx := context.Background()
	directory := privateDir(t)
	first := joinedTLSFixture(t, joinedFixtureOptions{loopbackSAN: true})
	credentials, err := SnapshotJoined(ctx, directory, joinedExecution, first)
	if err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(credentials.TLS.CertFile)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := SnapshotJoined(ctx, directory, joinedExecution, joinedTLSFixture(t, joinedFixtureOptions{loopbackSAN: true})); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(credentials.TLS.CertFile)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("same-execution snapshot replaced the joined identity")
	}
	other := "3123456789abcdef0123456789abcdef"
	if err := os.WriteFile(filepath.Join(directory, document(other)), before, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(ctx, directory, other); !errors.Is(err, ErrExecution) {
		t.Fatalf("copied joined identity error = %v, want ErrExecution", err)
	}
}

func TestSnapshotJoinedConcurrentReadAndRetry(t *testing.T) {
	ctx := context.Background()
	directory := privateDir(t)
	source := joinedTLSFixture(t, joinedFixtureOptions{loopbackSAN: true})
	if _, err := SnapshotJoined(ctx, directory, joinedExecution, source); err != nil {
		t.Fatal(err)
	}
	baseline, err := os.ReadFile(filepath.Join(directory, document(joinedExecution)))
	if err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	results := make(chan error, 24)
	var group sync.WaitGroup
	for index := range 24 {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			<-start
			if index%2 == 0 {
				_, err := SnapshotJoined(ctx, directory, joinedExecution, source)
				results <- err
				return
			}
			credentials, err := Load(ctx, directory, joinedExecution)
			if err == nil && !credentials.ExpiresAt.After(time.Now()) {
				err = ErrCredentials
			}
			results <- err
		}(index)
	}
	close(start)
	group.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	after, err := os.ReadFile(filepath.Join(directory, document(joinedExecution)))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(baseline, after) {
		t.Fatal("concurrent load/retry changed the execution snapshot")
	}
}

func TestSnapshotJoinedUsesPrivateDestinationAndRetainsExistingAPIs(t *testing.T) {
	ctx := context.Background()
	directory := privateDir(t)
	generated, err := Prepare(ctx, directory, "4123456789abcdef0123456789abcdef", time.Now().Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Load(ctx, directory, "4123456789abcdef0123456789abcdef"); err != nil {
		t.Fatal(err)
	}
	shared, err := PrepareShared(ctx, privateDir(t), "5123456789abcdef0123456789abcdef", time.Now().Add(time.Hour), privateDir(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Load(ctx, filepath.Dir(generated.TLS.CertFile), "4123456789abcdef0123456789abcdef"); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(ctx, filepath.Dir(shared.TLS.CertFile), "5123456789abcdef0123456789abcdef"); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(filepath.Base(generated.TLS.CertFile), "joined") || strings.Contains(filepath.Base(shared.TLS.CertFile), "joined") {
		t.Fatal("existing credential APIs were redirected to joined storage")
	}
}

func TestSnapshotJoinedRejectsDisabledOrMissingConfiguration(t *testing.T) {
	directory := privateDir(t)
	source := joinedTLSFixture(t, joinedFixtureOptions{loopbackSAN: true})
	source.Enabled = false
	if _, err := SnapshotJoined(context.Background(), directory, joinedExecution, source); !errors.Is(err, ErrCredentials) {
		t.Fatal(err)
	}
	source.Enabled = true
	source.CAFile = ""
	if _, err := SnapshotJoined(context.Background(), directory, joinedExecution, source); !errors.Is(err, ErrCredentials) {
		t.Fatal(err)
	}
	if _, err := Load(context.Background(), directory, joinedExecution); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
}
