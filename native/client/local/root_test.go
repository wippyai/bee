// SPDX-License-Identifier: MIT
package local

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net"
	"os"
	"testing"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
)

func TestRetainedRuntimeIdentitySurvivesMoreThanOneDay(t *testing.T) {
	_, certPEM, _, _, err := generateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(certPEM)
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	_, err = cert.Verify(x509.VerifyOptions{Roots: roots, DNSName: "localhost", CurrentTime: time.Now().Add(48 * time.Hour), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}})
	if err != nil {
		t.Fatalf("retained runtime stops admitting after one day: %v", err)
	}
}

func TestDialWithoutCallerDeadlineStillTimesOut(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			accepted <- conn
		}
	}()
	run, cert, key, _, err := generateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	descriptor := Descriptor{Version: DescriptorVersion, RunID: run, Endpoint: listener.Addr().String(), CertificatePEM: cert, PrivateKeyPEM: key}
	data, err := descriptor.Encode()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	file, err := privatefile.New(dir, DescriptorFileName, LockFileName)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.ReadModifyWrite(context.Background(), MaxDescriptorBytes, func([]byte) ([]byte, error) { return data, nil }); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		conn, err := Dial(context.Background(), dir)
		if conn != nil {
			conn.Close()
		}
		done <- err
	}()
	peer := <-accepted
	defer peer.Close()
	select {
	case err := <-done:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("expected bounded setup timeout: %v", err)
		}
	case <-time.After(DefaultSetupTimeout + time.Second):
		peer.Close()
		<-done
		t.Fatal("Dial has no default setup bound")
	}
}
