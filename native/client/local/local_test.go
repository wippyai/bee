// SPDX-License-Identifier: MIT

package local

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
)

func newTestDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "local-admission")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := privatefile.SetOwnerOnlyPermissions(dir); err != nil {
		t.Fatal(err)
	}
	return dir
}

// 1. Actual local listener, dial, and mutual auth data round-trip.
func TestLocalAdmissionMutualAuth(t *testing.T) {
	dir := newTestDir(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	ln, err := Start(ctx, dir)
	if err != nil {
		t.Fatalf("Start failed: %v", err)
	}
	defer ln.Close()

	if ln.Addr() == nil {
		t.Fatal("expected non-nil Addr")
	}
	if ln.Endpoint() == "" {
		t.Fatal("expected non-empty Endpoint")
	}
	if ln.RunID() == "" {
		t.Fatal("expected non-empty RunID")
	}

	serverDone := make(chan error, 1)
	go func() {
		conn, err := ln.Accept(ctx)
		if err != nil {
			serverDone <- fmt.Errorf("accept: %w", err)
			return
		}
		defer conn.Close()

		buf := make([]byte, 12)
		if _, err := io.ReadFull(conn, buf); err != nil {
			serverDone <- fmt.Errorf("server read: %w", err)
			return
		}
		if string(buf) != "client-hello" {
			serverDone <- fmt.Errorf("server received unexpected data: %q", string(buf))
			return
		}

		if _, err := conn.Write([]byte("server-reply")); err != nil {
			serverDone <- fmt.Errorf("server write: %w", err)
			return
		}
		serverDone <- nil
	}()

	clientConn, err := Dial(ctx, dir)
	if err != nil {
		t.Fatalf("Dial failed: %v", err)
	}
	defer clientConn.Close()

	tlsConn, ok := clientConn.(interface{ ConnectionState() tls.ConnectionState })
	if !ok {
		t.Fatalf("expected TLS connection state, got %T", clientConn)
	}
	cs := tlsConn.ConnectionState()
	if !cs.HandshakeComplete {
		t.Fatal("expected handshake complete")
	}
	if cs.Version != tls.VersionTLS13 {
		t.Fatalf("expected TLS 1.3, got 0x%x", cs.Version)
	}
	if len(cs.PeerCertificates) == 0 {
		t.Fatal("expected peer certificates on client connection")
	}

	if _, err := clientConn.Write([]byte("client-hello")); err != nil {
		t.Fatalf("client write failed: %v", err)
	}

	buf := make([]byte, 12)
	if _, err := io.ReadFull(clientConn, buf); err != nil {
		t.Fatalf("client read failed: %v", err)
	}
	if string(buf) != "server-reply" {
		t.Fatalf("client received unexpected reply: %q", string(buf))
	}

	if err := <-serverDone; err != nil {
		t.Fatalf("server error: %v", err)
	}
}

// 2. Wrong and stale credential refusal.
func TestWrongAndStaleCredentialRefusal(t *testing.T) {
	t.Run("ForeignClientCertRefused", func(t *testing.T) {
		subCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		dir := newTestDir(t)
		ln, err := Start(subCtx, dir)
		if err != nil {
			t.Fatal(err)
		}
		defer ln.Close()

		acceptErrCh := make(chan error, 1)
		go func() {
			conn, err := ln.Accept(subCtx)
			if err == nil {
				conn.Close()
				acceptErrCh <- errors.New("expected accept to fail, got connection")
				return
			}
			acceptErrCh <- err
		}()

		// Generate foreign keypair and cert
		foreignPub, foreignPriv, _ := ed25519.GenerateKey(rand.Reader)
		foreignTmpl := x509.Certificate{
			SerialNumber:          big.NewInt(99),
			Subject:               pkix.Name{CommonName: "localhost"},
			NotBefore:             time.Now().Add(-1 * time.Hour),
			NotAfter:              time.Now().Add(24 * time.Hour),
			KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
			ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
			BasicConstraintsValid: true,
			IsCA:                  true,
			DNSNames:              []string{"localhost"},
		}
		foreignDER, _ := x509.CreateCertificate(rand.Reader, &foreignTmpl, &foreignTmpl, foreignPub, foreignPriv)
		foreignCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: foreignDER})
		foreignPrivDER, _ := x509.MarshalPKCS8PrivateKey(foreignPriv)
		foreignPrivPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: foreignPrivDER})
		foreignTLS, err := tls.X509KeyPair(foreignCertPEM, foreignPrivPEM)
		if err != nil {
			t.Fatal(err)
		}

		foreignPool := x509.NewCertPool()
		foreignPool.AppendCertsFromPEM(foreignCertPEM)

		raw, err := net.Dial("tcp", ln.Endpoint())
		if err != nil {
			t.Fatal(err)
		}
		defer raw.Close()

		// Client dials using foreign cert and foreign root
		foreignClient := tls.Client(raw, &tls.Config{
			Certificates: []tls.Certificate{foreignTLS},
			RootCAs:      foreignPool,
			ServerName:   "localhost",
			MinVersion:   tls.VersionTLS13,
		})
		err = foreignClient.HandshakeContext(subCtx)
		if err == nil {
			t.Fatal("expected TLS handshake to fail with foreign certificate, got nil")
		}

		// Verify accept unblocks and rejects
		_ = ln.Close()
		<-acceptErrCh
	})

	t.Run("StaleDescriptorCannotAuthenticateToReplacementListener", func(t *testing.T) {
		subCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		dir := newTestDir(t)

		// Run 1 starts
		ln1, err := Start(subCtx, dir)
		if err != nil {
			t.Fatal(err)
		}
		desc1 := ln1.Descriptor()
		ln1.Close()

		// Run 2 starts in same directory (overwriting descriptor with fresh ephemeral identity)
		ln2, err := Start(subCtx, dir)
		if err != nil {
			t.Fatal(err)
		}
		defer ln2.Close()

		if ln1.RunID() == ln2.RunID() {
			t.Fatal("expected rotated RunID between runs")
		}

		go func() {
			conn, err := ln2.Accept(subCtx)
			if err == nil {
				_ = conn.Close()
			}
		}()

		// Client attempts to authenticate to ln2 using stale credentials from Run 1
		staleTLS, err := tls.X509KeyPair(desc1.CertificatePEM, desc1.PrivateKeyPEM)
		if err != nil {
			t.Fatal(err)
		}
		stalePool := x509.NewCertPool()
		stalePool.AppendCertsFromPEM(desc1.CertificatePEM)

		raw, err := net.Dial("tcp", ln2.Endpoint())
		if err != nil {
			t.Fatal(err)
		}
		defer raw.Close()

		staleClient := tls.Client(raw, &tls.Config{
			Certificates: []tls.Certificate{staleTLS},
			RootCAs:      stalePool,
			ServerName:   "localhost",
			MinVersion:   tls.VersionTLS13,
		})

		err = staleClient.HandshakeContext(subCtx)
		if err == nil {
			t.Fatal("expected handshake with stale credentials against replacement listener to fail, got nil")
		}
	})

	t.Run("RawGarbageRefused", func(t *testing.T) {
		subCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		dir := newTestDir(t)
		ln, err := Start(subCtx, dir)
		if err != nil {
			t.Fatal(err)
		}
		defer ln.Close()

		// Accept is running in background
		acceptCh := make(chan net.Conn, 1)
		acceptErrCh := make(chan error, 1)
		go func() {
			c, err := ln.Accept(subCtx)
			if err != nil {
				acceptErrCh <- err
				return
			}
			acceptCh <- c
		}()

		// Send raw garbage first
		raw, err := net.Dial("tcp", ln.Endpoint())
		if err != nil {
			t.Fatal(err)
		}
		_, _ = raw.Write([]byte("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
		_ = raw.Close()

		// Now legitimate client dials; Accept must admit the legitimate client
		time.Sleep(30 * time.Millisecond)
		clientConn, err := Dial(subCtx, dir)
		if err != nil {
			t.Fatalf("Dial failed after garbage probe: %v", err)
		}
		defer clientConn.Close()

		select {
		case serverConn := <-acceptCh:
			defer serverConn.Close()
		case err := <-acceptErrCh:
			t.Fatalf("Accept failed: %v", err)
		case <-time.After(3 * time.Second):
			t.Fatal("timed out waiting for accept after garbage probe")
		}
	})
}

// 3. Caller cancellation.
func TestCallerCancellation(t *testing.T) {
	dir := newTestDir(t)
	ln, err := Start(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	t.Run("AcceptCancellation", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() {
			_, err := ln.Accept(ctx)
			done <- err
		}()

		time.Sleep(50 * time.Millisecond)
		cancel()

		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("expected context.Canceled, got %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("Accept did not unblock on context cancellation")
		}
	})

	t.Run("DialCancellation", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // pre-cancelled

		_, err := Dial(ctx, dir)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	})
}

// 4. Setup timeout and cancel unblocks pending accept.
func TestSetupTimeoutAndCancellation(t *testing.T) {
	dir := newTestDir(t)

	t.Run("StartPreCancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := Start(ctx, dir)
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	})

	t.Run("StartExpiredTimeout", func(t *testing.T) {
		ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-1*time.Second))
		defer cancel()
		_, err := Start(ctx, dir)
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("expected context.DeadlineExceeded, got %v", err)
		}
	})
}

// 5. Descriptor read creates nothing.
func TestDescriptorReadCreatesNothing(t *testing.T) {
	ctx := context.Background()

	t.Run("NonExistentDirectory", func(t *testing.T) {
		nonExistent := filepath.Join(t.TempDir(), "does_not_exist_subpath")
		_, err := Dial(ctx, nonExistent)
		if err == nil {
			t.Fatal("expected error on non-existent directory")
		}
		if _, statErr := os.Stat(nonExistent); !errors.Is(statErr, os.ErrNotExist) {
			t.Fatalf("expected path to not be created, got stat error: %v", statErr)
		}
	})

	t.Run("EmptyDirectory", func(t *testing.T) {
		dir := newTestDir(t)
		_, err := Dial(ctx, dir)
		if err == nil {
			t.Fatal("expected error on empty directory")
		}
		entries, readErr := os.ReadDir(dir)
		if readErr != nil {
			t.Fatal(readErr)
		}
		if len(entries) != 0 {
			t.Fatalf("expected 0 files created, found %d entries", len(entries))
		}
	})
}

// 6. Invalid descriptor and insecure permissions refusal.
func TestInvalidDescriptorAndPermissions(t *testing.T) {
	ctx := context.Background()

	t.Run("InsecureDirectoryPermissionsRefusedWithoutRepair", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "insecure_dir")
		if err := os.Mkdir(dir, 0777); err != nil {
			t.Fatal(err)
		}
		_ = os.Chmod(dir, 0777)

		_, err := Start(ctx, dir)
		if err == nil {
			t.Fatal("expected Start to fail on insecure directory")
		}

		// Verify permissions were NOT repaired
		fi, err := os.Stat(dir)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm()&0077 == 0 {
			t.Fatal("directory permissions were unexpectedly repaired")
		}

		_, err = Dial(ctx, dir)
		if err == nil {
			t.Fatal("expected Dial to fail on insecure directory")
		}
	})

	t.Run("InsecureDescriptorFilePermissionsRefused", func(t *testing.T) {
		dir := newTestDir(t)
		filePath := filepath.Join(dir, DescriptorFileName)
		if err := os.WriteFile(filePath, []byte("{}"), 0666); err != nil {
			t.Fatal(err)
		}
		_ = os.Chmod(filePath, 0666)

		_, err := Dial(ctx, dir)
		if err == nil {
			t.Fatal("expected Dial to fail on insecure file permissions")
		}

		fi, err := os.Stat(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm()&0066 == 0 {
			t.Fatal("file permissions were unexpectedly repaired")
		}
	})

	testCases := []struct {
		name    string
		content string
	}{
		{"MalformedJSON", `{"version": 1, "endpoint": `},
		{"UnknownField", `{"version": 1, "run_id": "1234567890abcdef", "endpoint": "127.0.0.1:8080", "certificate_pem": "a", "private_key_pem": "b", "unknown": 123}`},
		{"DuplicateField", `{"version": 1, "version": 1, "run_id": "1234567890abcdef", "endpoint": "127.0.0.1:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
		{"NullField", `{"version": 1, "run_id": null, "endpoint": "127.0.0.1:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
		{"MissingField", `{"version": 1, "endpoint": "127.0.0.1:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
		{"NonLoopbackEndpoint", `{"version": 1, "run_id": "1234567890abcdef", "endpoint": "192.168.1.1:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
		{"ZeroIPEndpoint", `{"version": 1, "run_id": "1234567890abcdef", "endpoint": "0.0.0.0:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
		{"HostnameEndpoint", `{"version": 1, "run_id": "1234567890abcdef", "endpoint": "localhost:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
		{"UnsupportedVersion", `{"version": 2, "run_id": "1234567890abcdef", "endpoint": "127.0.0.1:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
		{"FloatVersion", `{"version": 1.5, "run_id": "1234567890abcdef", "endpoint": "127.0.0.1:8080", "certificate_pem": "a", "private_key_pem": "b"}`},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			dir := newTestDir(t)
			filePath := filepath.Join(dir, DescriptorFileName)
			if err := os.WriteFile(filePath, []byte(tc.content), 0600); err != nil {
				t.Fatal(err)
			}

			_, err := Dial(ctx, dir)
			if err == nil {
				t.Fatalf("expected error for case %s, got nil", tc.name)
			}
			if !errors.Is(err, ErrInvalidDescriptor) {
				t.Fatalf("expected ErrInvalidDescriptor for case %s, got %v", tc.name, err)
			}
		})
	}

	t.Run("InvalidUTF8", func(t *testing.T) {
		dir := newTestDir(t)
		filePath := filepath.Join(dir, DescriptorFileName)
		if err := os.WriteFile(filePath, []byte{0xff, 0xfe, 0xfd}, 0600); err != nil {
			t.Fatal(err)
		}
		_, err := Dial(ctx, dir)
		if !errors.Is(err, ErrInvalidDescriptor) {
			t.Fatalf("expected ErrInvalidDescriptor on invalid UTF-8, got %v", err)
		}
	})

	t.Run("NullByte", func(t *testing.T) {
		dir := newTestDir(t)
		filePath := filepath.Join(dir, DescriptorFileName)
		if err := os.WriteFile(filePath, []byte("{\"version\": 1\x00}"), 0600); err != nil {
			t.Fatal(err)
		}
		_, err := Dial(ctx, dir)
		if !errors.Is(err, ErrInvalidDescriptor) {
			t.Fatalf("expected ErrInvalidDescriptor on null byte, got %v", err)
		}
	})

	t.Run("KeyAndCertificateMismatch", func(t *testing.T) {
		// Generate keypair 1
		pub1, priv1, _ := ed25519.GenerateKey(rand.Reader)
		tmpl := x509.Certificate{
			SerialNumber:          big.NewInt(1),
			Subject:               pkix.Name{CommonName: "localhost"},
			NotBefore:             time.Now().Add(-1 * time.Hour),
			NotAfter:              time.Now().Add(24 * time.Hour),
			KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
			ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
			BasicConstraintsValid: true,
			IsCA:                  true,
			DNSNames:              []string{"localhost"},
		}
		der1, _ := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, pub1, priv1)
		certPEM1 := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der1})

		// Generate keypair 2
		_, priv2, _ := ed25519.GenerateKey(rand.Reader)
		privDER2, _ := x509.MarshalPKCS8PrivateKey(priv2)
		privPEM2 := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER2})

		dir := newTestDir(t)
		rec := persistedDescriptor{
			Version:        1,
			RunID:          "1234567890abcdef",
			Endpoint:       "127.0.0.1:9090",
			CertificatePEM: string(certPEM1),
			PrivateKeyPEM:  string(privPEM2),
		}
		data, _ := json.Marshal(rec)
		if err := os.WriteFile(filepath.Join(dir, DescriptorFileName), data, 0600); err != nil {
			t.Fatal(err)
		}

		_, err := Dial(ctx, dir)
		if !errors.Is(err, ErrInvalidDescriptor) {
			t.Fatalf("expected ErrInvalidDescriptor on mismatched key/cert, got %v", err)
		}
	})

	t.Run("SymlinkDescriptorRefused", func(t *testing.T) {
		dir := newTestDir(t)
		targetFile := filepath.Join(t.TempDir(), "target.json")
		if err := os.WriteFile(targetFile, []byte("{}"), 0600); err != nil {
			t.Fatal(err)
		}
		linkPath := filepath.Join(dir, DescriptorFileName)
		if err := os.Symlink(targetFile, linkPath); err != nil {
			t.Fatal(err)
		}
		_, err := Dial(ctx, dir)
		if err == nil {
			t.Fatal("expected Dial to fail on symlink descriptor")
		}
	})

	t.Run("TrailingPEMContentRefused", func(t *testing.T) {
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		tmpl := x509.Certificate{
			SerialNumber:          big.NewInt(1),
			Subject:               pkix.Name{CommonName: "localhost"},
			NotBefore:             time.Now().Add(-1 * time.Hour),
			NotAfter:              time.Now().Add(24 * time.Hour),
			KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
			ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
			BasicConstraintsValid: true,
			IsCA:                  true,
			DNSNames:              []string{"localhost"},
		}
		der, _ := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, pub, priv)
		certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		certPEMWithTrailing := string(certPEM) + "\nEXTRA UNEXPECTED TRAILING DATA\n"

		privDER, _ := x509.MarshalPKCS8PrivateKey(priv)
		privPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER})

		dir := newTestDir(t)
		rec := persistedDescriptor{
			Version:        1,
			RunID:          "1234567890abcdef",
			Endpoint:       "127.0.0.1:9090",
			CertificatePEM: certPEMWithTrailing,
			PrivateKeyPEM:  string(privPEM),
		}
		data, _ := json.Marshal(rec)
		if err := os.WriteFile(filepath.Join(dir, DescriptorFileName), data, 0600); err != nil {
			t.Fatal(err)
		}

		_, err := Dial(ctx, dir)
		if !errors.Is(err, ErrInvalidDescriptor) {
			t.Fatalf("expected ErrInvalidDescriptor on trailing PEM content, got %v", err)
		}
	})

	t.Run("TrailingJSONContentRefused", func(t *testing.T) {
		dir := newTestDir(t)
		content := `{"version": 1, "run_id": "1234567890abcdef", "endpoint": "127.0.0.1:8080", "certificate_pem": "a", "private_key_pem": "b"} {"second": 2}`
		if err := os.WriteFile(filepath.Join(dir, DescriptorFileName), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		_, err := Dial(ctx, dir)
		if !errors.Is(err, ErrInvalidDescriptor) {
			t.Fatalf("expected ErrInvalidDescriptor on trailing JSON content, got %v", err)
		}
	})
}

// 7. Publication failure cleanup.
func TestPublicationFailureCleanup(t *testing.T) {
	ctx := context.Background()

	t.Run("UnwritableDirectoryCleansUpListener", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "ro_dir")
		if err := os.Mkdir(dir, 0500); err != nil { // read-only
			t.Fatal(err)
		}
		defer os.Chmod(dir, 0700)

		_, err := Start(ctx, dir)
		if err == nil {
			t.Fatal("expected Start to fail on read-only directory")
		}
	})

	t.Run("PreservesPublishedSyncErrorUncertainty", func(t *testing.T) {
		syncErr := &privatefile.PublishedSyncError{Err: errors.New("directory fsync failed")}
		var target *privatefile.PublishedSyncError
		if !errors.As(syncErr, &target) {
			t.Fatal("expected errors.As(syncErr, &target) to be true")
		}
		if !errors.Is(syncErr, privatefile.ErrPublishedSyncFailed) {
			t.Fatal("expected errors.Is(syncErr, ErrPublishedSyncFailed) to be true")
		}
	})
}

// 8. Accepted connection survives setup context cancellation.
func TestAcceptedConnectionSurvivesSetupCancellation(t *testing.T) {
	dir := newTestDir(t)

	setupCtx, cancelSetup := context.WithCancel(context.Background())
	ln, err := Start(setupCtx, dir)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	// Cancel setup context immediately after Start returns
	cancelSetup()

	// Verify listener is still functional
	acceptCh := make(chan net.Conn, 1)
	acceptErrCh := make(chan error, 1)
	go func() {
		conn, err := ln.Accept(context.Background())
		if err != nil {
			acceptErrCh <- err
			return
		}
		acceptCh <- conn
	}()

	clientConn, err := Dial(context.Background(), dir)
	if err != nil {
		t.Fatalf("Dial failed after setup context cancellation: %v", err)
	}
	defer clientConn.Close()

	select {
	case serverConn := <-acceptCh:
		defer serverConn.Close()

		// Write and read on the accepted connection to ensure survival
		if _, err := clientConn.Write([]byte("survive-test")); err != nil {
			t.Fatalf("write failed: %v", err)
		}
		buf := make([]byte, 12)
		if _, err := io.ReadFull(serverConn, buf); err != nil {
			t.Fatalf("read failed: %v", err)
		}
		if string(buf) != "survive-test" {
			t.Fatalf("received unexpected: %s", string(buf))
		}
	case err := <-acceptErrCh:
		t.Fatalf("Accept failed: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for accept")
	}
}

// 9. No key echo in errors or formatted strings.
func TestNoKeyEcho(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	privDER, _ := x509.MarshalPKCS8PrivateKey(priv)
	privPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER})
	privPEMStr := string(privPEM)

	// Create descriptor with valid key but corrupted version
	rawJSON := fmt.Sprintf(`{
		"version": 999,
		"run_id": "test-run-id-12345",
		"endpoint": "127.0.0.1:8888",
		"certificate_pem": "invalid",
		"private_key_pem": %q
	}`, privPEMStr)

	_, err := ParseDescriptor([]byte(rawJSON))
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	errStr := err.Error()

	if strings.Contains(errStr, privPEMStr) {
		t.Fatal("error string contains raw private key PEM")
	}
	if strings.Contains(errStr, "PRIVATE KEY") {
		t.Fatal("error string contains 'PRIVATE KEY'")
	}
	if strings.Contains(errStr, hex.EncodeToString(priv)) {
		t.Fatal("error string contains private key hex bytes")
	}

	// Verify Descriptor string formatters
	desc := &Descriptor{
		Version:        1,
		RunID:          "run-12345678",
		Endpoint:       "127.0.0.1:1234",
		CertificatePEM: []byte("cert"),
		PrivateKeyPEM:  privPEM,
	}

	formats := []string{
		fmt.Sprintf("%v", desc),
		fmt.Sprintf("%+v", desc),
		fmt.Sprintf("%#v", desc),
		fmt.Sprintf("%s", desc),
		desc.String(),
		desc.GoString(),
	}

	for i, formatted := range formats {
		if strings.Contains(formatted, privPEMStr) || strings.Contains(formatted, "PRIVATE KEY") || strings.Contains(formatted, hex.EncodeToString(priv)) {
			t.Fatalf("formatted output %d leaked private key: %s", i, formatted)
		}
	}
}

// 10. Wrong or slow clients cannot monopolize the listener.
func TestWrongClientsCannotMonopolize(t *testing.T) {
	dir := newTestDir(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	ln, err := Start(ctx, dir)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	// 1. Rogue client connects and stalls (sends nothing)
	rogueConn, err := net.Dial("tcp", ln.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer rogueConn.Close()

	acceptCh := make(chan net.Conn, 1)
	acceptErrCh := make(chan error, 1)
	go func() {
		c, err := ln.Accept(ctx)
		if err != nil {
			acceptErrCh <- err
			return
		}
		acceptCh <- c
	}()

	// 2. Legitimate client dials immediately while rogue client is stalled
	time.Sleep(50 * time.Millisecond)
	clientConn, err := Dial(ctx, dir)
	if err != nil {
		t.Fatalf("legitimate dial failed: %v", err)
	}
	defer clientConn.Close()

	select {
	case serverConn := <-acceptCh:
		defer serverConn.Close()
		// Round trip check
		if _, err := clientConn.Write([]byte("ping")); err != nil {
			t.Fatal(err)
		}
		buf := make([]byte, 4)
		if _, err := io.ReadFull(serverConn, buf); err != nil {
			t.Fatal(err)
		}
		if string(buf) != "ping" {
			t.Fatalf("unexpected: %s", string(buf))
		}
	case err := <-acceptErrCh:
		t.Fatalf("Accept error: %v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("Accept blocked by stalled rogue client (monopolization defect)")
	}
}

// 11. Concurrent Accept guard prevents global deadline races.
func TestConcurrentAcceptGuard(t *testing.T) {
	dir := newTestDir(t)
	ln, err := Start(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	ctx1, cancel1 := context.WithCancel(context.Background())
	defer cancel1()

	started1 := make(chan struct{})
	go func() {
		close(started1)
		_, _ = ln.Accept(ctx1)
	}()

	<-started1
	time.Sleep(30 * time.Millisecond)

	// Second concurrent Accept call must fail immediately with ErrAcceptInProgress
	_, err2 := ln.Accept(context.Background())
	if !errors.Is(err2, ErrAcceptInProgress) {
		t.Fatalf("expected ErrAcceptInProgress, got %v", err2)
	}

	cancel1()
	time.Sleep(50 * time.Millisecond)

	// After Goroutine 1 completes, Accept is available again
	ctx3, cancel3 := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel3()
	_, err3 := ln.Accept(ctx3)
	if !errors.Is(err3, context.DeadlineExceeded) {
		t.Fatalf("expected deadline exceeded on idle accept, got %v", err3)
	}
}

// 12. Listener.Close is idempotent and cleans up pending handshakes.
func TestListenerCloseIdempotentAndPendingHandshakeCleanup(t *testing.T) {
	dir := newTestDir(t)
	ln, err := Start(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}

	// Connect a stalling client
	raw, err := net.Dial("tcp", ln.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	acceptErrCh := make(chan error, 1)
	go func() {
		_, err := ln.Accept(context.Background())
		acceptErrCh <- err
	}()

	time.Sleep(50 * time.Millisecond)

	// First Close
	if err := ln.Close(); err != nil {
		t.Fatalf("first Close failed: %v", err)
	}

	// Verify accept unblocks with ErrClosed
	select {
	case err := <-acceptErrCh:
		if !errors.Is(err, ErrClosed) {
			t.Fatalf("expected ErrClosed, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Accept did not unblock upon Listener.Close")
	}

	// Second Close (idempotent)
	if err := ln.Close(); err != nil {
		t.Fatalf("second Close failed: %v", err)
	}

	// Subsequent Accept returns ErrClosed immediately
	_, err = ln.Accept(context.Background())
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed on closed listener, got %v", err)
	}
}

// 13. Admitted connections survive Listener.Close.
func TestAdmittedConnectionSurvivesListenerClose(t *testing.T) {
	dir := newTestDir(t)
	ln, err := Start(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}

	acceptCh := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept(context.Background())
		if err == nil {
			acceptCh <- c
		}
	}()

	clientConn, err := Dial(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()

	serverConn := <-acceptCh
	defer serverConn.Close()

	// Close listener
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}

	// Admitted connections survive and can still transfer data
	if _, err := clientConn.Write([]byte("post-close-ping")); err != nil {
		t.Fatalf("write after listener close failed: %v", err)
	}

	buf := make([]byte, 15)
	if _, err := io.ReadFull(serverConn, buf); err != nil {
		t.Fatalf("read after listener close failed: %v", err)
	}
	if string(buf) != "post-close-ping" {
		t.Fatalf("unexpected data: %s", string(buf))
	}
}

// 14. Descriptor kept on Close.
func TestDescriptorKeptOnClose(t *testing.T) {
	dir := newTestDir(t)
	ln, err := Start(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}

	descPath := filepath.Join(dir, DescriptorFileName)
	if _, err := os.Stat(descPath); err != nil {
		t.Fatalf("descriptor does not exist: %v", err)
	}

	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}

	// Descriptor must STILL exist
	if _, err := os.Stat(descPath); err != nil {
		t.Fatalf("descriptor was unexpectedly removed on Close: %v", err)
	}
}

// 15. Relative directory rejected.
func TestRelativeDirectoryRejected(t *testing.T) {
	ctx := context.Background()
	_, err := Start(ctx, "./relative_path")
	if err == nil {
		t.Fatal("expected Start with relative path to fail")
	}

	_, err = Dial(ctx, "./relative_path")
	if err == nil {
		t.Fatal("expected Dial with relative path to fail")
	}
}
