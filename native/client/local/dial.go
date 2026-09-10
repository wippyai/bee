// SPDX-License-Identifier: MIT

package local

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"path/filepath"

	"github.com/wippyai/bee/native/internal/privatefile"
)

// Dial discovers and authenticates to a local physical-client endpoint published in directory.
//
// Invariants:
//   - directory must be an absolute path.
//   - Reads the descriptor file strictly via internal/privatefile without creating the directory
//     or any files. If the descriptor is missing, os.ErrNotExist is returned without mutation.
//   - Rejects malformed, incomplete, duplicate, unknown, or null descriptor fields, as well
//     as non-loopback endpoints or mismatched keys.
//   - Completes standard mutual TLS handshake using the descriptor's ephemeral Ed25519 CA
//     certificate as the trust root and client credential.
//   - Returns an authenticated net.Conn on success. On failure, all intermediate handles are
//     closed and no secrets are revealed in errors.
func Dial(ctx context.Context, directory string) (net.Conn, error) {
	if ctx == nil {
		return nil, errors.New("client/local: context is required")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(directory) {
		return nil, errors.New("client/local: directory must be an absolute path")
	}

	ctx, cancel := context.WithTimeout(ctx, DefaultSetupTimeout)
	defer cancel()

	cleanDir := filepath.Clean(directory)
	pf, err := privatefile.New(cleanDir, DescriptorFileName, LockFileName)
	if err != nil {
		return nil, err
	}

	data, err := pf.Read(ctx, MaxDescriptorBytes)
	if err != nil {
		return nil, fmt.Errorf("client/local: read descriptor: %w", err)
	}

	desc, err := ParseDescriptor(data)
	if err != nil {
		return nil, fmt.Errorf("client/local: %w", err)
	}

	tlsCert, err := tls.X509KeyPair(desc.CertificatePEM, desc.PrivateKeyPEM)
	if err != nil {
		return nil, errors.New("client/local: failed to load client TLS keypair")
	}

	certPool := x509.NewCertPool()
	if !certPool.AppendCertsFromPEM(desc.CertificatePEM) {
		return nil, errors.New("client/local: failed to append CA certificate to pool")
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		RootCAs:      certPool,
		ServerName:   "localhost",
		MinVersion:   tls.VersionTLS13,
	}

	var dialer net.Dialer
	rawConn, err := dialer.DialContext(ctx, "tcp", desc.Endpoint)
	if err != nil {
		return nil, fmt.Errorf("client/local: dial endpoint: %w", err)
	}

	tlsConn := tls.Client(rawConn, tlsConfig)
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = rawConn.Close()
		return nil, fmt.Errorf("client/local: tls handshake: %w", err)
	}

	state := tlsConn.ConnectionState()
	if !state.HandshakeComplete || len(state.PeerCertificates) == 0 {
		_ = tlsConn.Close()
		return nil, errors.New("client/local: incomplete tls handshake or missing peer certificate")
	}

	return &connection{tlsConn}, nil
}
