//go:build meshclient

// SPDX-License-Identifier: MIT

// Package localtls provisions same-account credentials for native loopback mesh.
// It creates no listener and grants no desktop or application authority.
package localtls

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
	"github.com/wippyai/runtime/cluster/internode"
)

func document(execution string) string { return "local-tls-" + execution + ".pem" }

// Credentials is selected by the native owner/client, never remote metadata.
// The owner must stop its mesh by ExpiresAt; certificate expiry alone does not
// revoke already established connections.
type Credentials struct {
	TLS       internode.ManagerTLSConfig
	ExpiresAt time.Time
}

const maxBytes = 8192
const maxLifetime = 30 * 24 * time.Hour

var ErrCredentials = errors.New("Bee local TLS credentials invalid or unavailable")
var ErrExecution = errors.New("Bee local TLS credentials belong to another execution")

// Prepare is called only by the native owner while holding its application-state
// lock, before mesh startup and rendezvous publication. It atomically writes one
// PEM bundle: runtime certificate, private key and trust anchor paths all refer
// to it. Same-execution retries retain the existing identity. A new execution
// gets a fresh filename; old files are not replaced or removed. Malformed or
// insecure existing files are never repaired.
//
// The host explicitly selects expiry, at most 30 days away. Expired credentials
// require a new owner execution, not silent key rotation in a running transport.
// The shared key establishes same-OS-account access only. Native signed-node
// enrollment still distinguishes peers; the supervisor separately admits them.
func Prepare(ctx context.Context, directory, execution string, expires time.Time) (Credentials, error) {
	return prepare(ctx, directory, execution, expires, time.Now())
}

func prepare(ctx context.Context, directory, execution string, expires, now time.Time) (Credentials, error) {
	expires = expires.Truncate(time.Second)
	if !validExecution(execution) || !expires.After(now) || expires.Sub(now) > maxLifetime {
		return Credentials{}, ErrCredentials
	}
	file, err := privatefile.New(directory, document(execution), ".local-tls-"+execution+".lock")
	if err != nil {
		return Credentials{}, err
	}
	err = file.ReadModifyWrite(ctx, maxBytes, func(existing []byte) ([]byte, error) {
		// ReadModifyWrite returns nil only when the document is missing. An
		// existing empty document is still an existing credential and must fail
		// validation rather than being silently repaired.
		if existing != nil {
			certificate, err := decode(existing)
			if err != nil {
				return nil, err
			}
			if err := validate(certificate, execution, now); err != nil {
				return nil, err
			}
			expires = certificate.NotAfter
			return nil, nil
		}
		return generate(execution, now, expires)
	})
	if err != nil {
		return Credentials{}, err
	}
	return config(directory, execution, expires), nil
}

// Load reads protected credentials for exactly the advertised owner execution.
// Missing, expired, mismatched or insecure credentials fail without any writes.
// Only use the resulting configuration after validating loopback endpoints.
func Load(ctx context.Context, directory, execution string) (Credentials, error) {
	return load(ctx, directory, execution, time.Now())
}

func load(ctx context.Context, directory, execution string, now time.Time) (Credentials, error) {
	if !validExecution(execution) {
		return Credentials{}, ErrCredentials
	}
	file, err := privatefile.New(directory, document(execution), ".local-tls-"+execution+".lock")
	if err != nil {
		return Credentials{}, err
	}
	data, err := file.Read(ctx, maxBytes)
	if err != nil {
		return Credentials{}, err
	}
	certificate, err := decode(data)
	if err != nil {
		return Credentials{}, err
	}
	if err := validate(certificate, execution, now); err != nil {
		return Credentials{}, err
	}
	return config(directory, execution, certificate.NotAfter), nil
}

func config(directory, execution string, expires time.Time) Credentials {
	path := filepath.Join(directory, document(execution))
	return Credentials{TLS: internode.ManagerTLSConfig{Enabled: true, CAFile: path, CertFile: path, KeyFile: path}, ExpiresAt: expires}
}

func validExecution(execution string) bool {
	decoded, err := hex.DecodeString(execution)
	return err == nil && len(decoded) == 16 && hex.EncodeToString(decoded) == execution
}

func generate(execution string, now, expires time.Time) ([]byte, error) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, err
	}
	serial.Add(serial, big.NewInt(1))
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "Bee local mesh", SerialNumber: execution},
		NotBefore: now.Add(-time.Minute), NotAfter: expires,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		return nil, err
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		return nil, err
	}
	result := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return append(result, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})...), nil
}

func decode(data []byte) (*x509.Certificate, error) {
	certBlock, rest := pem.Decode(data)
	if certBlock == nil || certBlock.Type != "CERTIFICATE" || len(certBlock.Headers) != 0 {
		return nil, ErrCredentials
	}
	keyBlock, tail := pem.Decode(rest)
	if keyBlock == nil || keyBlock.Type != "PRIVATE KEY" || len(keyBlock.Headers) != 0 || len(bytes.TrimSpace(tail)) != 0 {
		return nil, ErrCredentials
	}
	if !bytes.Equal(data, append(pem.EncodeToMemory(certBlock), pem.EncodeToMemory(keyBlock)...)) {
		return nil, ErrCredentials
	}
	certificate, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil || certificate.PublicKeyAlgorithm != x509.Ed25519 || !validExecution(certificate.Subject.SerialNumber) {
		return nil, ErrCredentials
	}
	if _, err := tls.X509KeyPair(data, data); err != nil {
		return nil, ErrCredentials
	}
	if err := certificate.CheckSignature(certificate.SignatureAlgorithm, certificate.RawTBSCertificate, certificate.Signature); err != nil {
		return nil, ErrCredentials
	}
	if certificate.IsCA || !certificate.BasicConstraintsValid || certificate.KeyUsage != x509.KeyUsageDigitalSignature || len(certificate.ExtKeyUsage) != 2 || certificate.ExtKeyUsage[0] != x509.ExtKeyUsageClientAuth || certificate.ExtKeyUsage[1] != x509.ExtKeyUsageServerAuth || len(certificate.DNSNames) != 0 || len(certificate.IPAddresses) != 2 || !certificate.IPAddresses[0].Equal(net.ParseIP("127.0.0.1")) || !certificate.IPAddresses[1].Equal(net.ParseIP("::1")) {
		return nil, ErrCredentials
	}
	return certificate, nil
}

func validate(certificate *x509.Certificate, execution string, now time.Time) error {
	if certificate.Subject.SerialNumber != execution {
		return ErrExecution
	}
	if now.Before(certificate.NotBefore) || !now.Before(certificate.NotAfter) {
		return ErrCredentials
	}
	return nil
}
