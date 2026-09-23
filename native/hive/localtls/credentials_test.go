//go:build meshclient

// SPDX-License-Identifier: MIT
package localtls

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"github.com/wippyai/bee/native/internal/privatefile"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const first = "0123456789abcdef0123456789abcdef"
const second = "1123456789abcdef0123456789abcdef"

func TestExecutionRotationAndRetry(t *testing.T) {
	ctx, dir, now := context.Background(), privateDir(t), time.Now().Truncate(time.Second)
	config, err := prepare(ctx, dir, first, now.Add(time.Hour), now)
	if err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(config.TLS.CertFile)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := prepare(ctx, dir, first, now.Add(2*time.Hour), now); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(config.TLS.CertFile)
	if !bytes.Equal(before, after) {
		t.Fatal("same execution rotated credentials")
	}
	if _, err := load(ctx, dir, second, now); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if _, err := prepare(ctx, dir, second, now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	if _, err := load(ctx, dir, first, now); err != nil {
		t.Fatal("new execution removed old material:", err)
	}
	oldBytes, _ := os.ReadFile(config.TLS.CertFile)
	if !bytes.Equal(before, oldBytes) {
		t.Fatal("new execution replaced old material")
	}
	if _, err := load(ctx, dir, second, now); err != nil {
		t.Fatal(err)
	}
}

func TestCertificateVerifiesBothLoopbackFamiliesAndRoles(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	config, err := prepare(context.Background(), privateDir(t), first, now.Add(time.Hour), now)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.LoadX509KeyPair(config.TLS.CertFile, config.TLS.KeyFile)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	for _, address := range []string{"127.0.0.1", "::1"} {
		for _, role := range []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth} {
			if _, err := cert.Verify(x509.VerifyOptions{Roots: roots, CurrentTime: now, DNSName: address, KeyUsages: []x509.ExtKeyUsage{role}}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := cert.Verify(x509.VerifyOptions{Roots: roots, CurrentTime: now, DNSName: "100.70.10.28"}); err == nil {
		t.Fatal("certificate allowed LAN address")
	}
}

func TestUnavailableCredentialsNeverRepaired(t *testing.T) {
	ctx, now := context.Background(), time.Now().Truncate(time.Second)
	dir := filepath.Join(privateDir(t), "missing")
	if _, err := load(ctx, dir, first, now); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("read created state")
	}
	dir = privateDir(t)
	if err := os.WriteFile(filepath.Join(dir, document(first)), []byte("malformed"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := prepare(ctx, dir, first, now.Add(time.Hour), now); !errors.Is(err, ErrCredentials) {
		t.Fatal(err)
	}
	unchanged, _ := os.ReadFile(filepath.Join(dir, document(first)))
	if string(unchanged) != "malformed" {
		t.Fatal("malformed file replaced")
	}
	if err := os.WriteFile(filepath.Join(dir, document(second)), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := prepare(ctx, dir, second, now.Add(time.Hour), now); !errors.Is(err, ErrCredentials) {
		t.Fatalf("empty existing file error = %v, want %v", err, ErrCredentials)
	}
	unchanged, readErr := os.ReadFile(filepath.Join(dir, document(second)))
	if readErr != nil {
		t.Fatal(readErr)
	}
	if len(unchanged) != 0 {
		t.Fatal("empty existing file replaced")
	}
}

func TestExpiryRequiresNewExecution(t *testing.T) {
	ctx, dir, now := context.Background(), privateDir(t), time.Now().Truncate(time.Second)
	if _, err := prepare(ctx, dir, first, now.Add(time.Hour), now); err != nil {
		t.Fatal(err)
	}
	expired := now.Add(time.Hour)
	if _, err := load(ctx, dir, first, expired); !errors.Is(err, ErrCredentials) {
		t.Fatal(err)
	}
	if _, err := prepare(ctx, dir, first, expired.Add(time.Hour), expired); !errors.Is(err, ErrCredentials) {
		t.Fatal(err)
	}
	if _, err := prepare(ctx, dir, second, expired.Add(time.Hour), expired); err != nil {
		t.Fatal(err)
	}
}

func TestCopiedCredentialCannotClaimAnotherExecution(t *testing.T) {
	ctx, dir, now := context.Background(), privateDir(t), time.Now().Truncate(time.Second)
	original, err := prepare(ctx, dir, first, now.Add(time.Hour), now)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(original.TLS.CertFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, document(second)), data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := load(ctx, dir, second, now); !errors.Is(err, ErrExecution) {
		t.Fatal(err)
	}
	if _, err := prepare(ctx, dir, second, now.Add(time.Hour), now); !errors.Is(err, ErrExecution) {
		t.Fatal(err)
	}
}

func privateDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "private")
	if err := privatefile.EnsurePrivateDir(dir); err != nil {
		t.Fatal(err)
	}
	return dir
}
