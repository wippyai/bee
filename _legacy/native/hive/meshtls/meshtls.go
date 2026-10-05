// SPDX-License-Identifier: MIT

// Package meshtls issues the internode TLS credentials of a Bee node's mesh.
// Every node owns an authority. It signs its own leaf and the leaf of each
// node that joins its hive, so the hive side trusts a joined node without
// reloading its pool. A joined node trusts its own authority and the pool of
// the node it joined. TLS grants confidentiality and hive membership only;
// node identity stays with the pinned internode Ed25519 keys.
package meshtls

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"net/netip"
	"path/filepath"
	"time"

	"github.com/wippyai/runtime/cluster/internode"
)

const (
	// AuthorityFile holds a node's own authority certificate and key.
	AuthorityFile = "authority.pem"
	// CredentialFile holds the active leaf certificate and its key; it is the
	// runtime's cert_file and key_file.
	CredentialFile = "mesh.pem"
	// AuthoritiesFile holds the trusted authority certificates; it is the
	// runtime's ca_file.
	AuthoritiesFile = "mesh-authorities.pem"

	authorityName     = "Bee Hive mesh authority"
	leafName          = "Bee Hive mesh node"
	authorityLifetime = 10 * 365 * 24 * time.Hour
	// LeafLifetime bounds every issued leaf; the issuing authority's expiry
	// bounds it further.
	LeafLifetime = 365 * 24 * time.Hour
	// MaxBytes bounds every PEM document this package decodes.
	MaxBytes       = 64 * 1024
	maxAuthorities = 16
)

// ErrCredentials refuses a malformed, mismatched or expired credential.
var ErrCredentials = errors.New("invalid Bee mesh credentials")

// Authority is one node's own certificate authority.
type Authority struct {
	certificate *x509.Certificate
	key         ed25519.PrivateKey
}

// Config names the credential files in directory as the runtime's internode
// TLS configuration. There is no plaintext fallback once TLS is selected.
func Config(directory string) internode.ManagerTLSConfig {
	credential := filepath.Join(directory, CredentialFile)
	return internode.ManagerTLSConfig{Enabled: true, CertFile: credential, KeyFile: credential, CAFile: filepath.Join(directory, AuthoritiesFile)}
}

func serial() (*big.Int, error) {
	value, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return nil, err
	}
	return value.Add(value, big.NewInt(1)), nil
}

// NewAuthority creates a fresh authority document.
func NewAuthority(now time.Time) ([]byte, error) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	number, err := serial()
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{SerialNumber: number, Subject: pkix.Name{CommonName: authorityName},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(authorityLifetime).Truncate(time.Second),
		IsCA: true, BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		return nil, err
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		return nil, err
	}
	return append(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})...), nil
}

func authorityCertificate(der []byte) (*x509.Certificate, error) {
	root, err := x509.ParseCertificate(der)
	if err != nil || !root.IsCA || !root.BasicConstraintsValid || root.PublicKeyAlgorithm != x509.Ed25519 ||
		root.KeyUsage != x509.KeyUsageCertSign|x509.KeyUsageDigitalSignature || !root.MaxPathLenZero || root.MaxPathLen != 0 ||
		root.Subject.CommonName != authorityName {
		return nil, ErrCredentials
	}
	if err := root.CheckSignatureFrom(root); err != nil {
		return nil, ErrCredentials
	}
	return root, nil
}

// DecodeAuthority validates an authority document and its key.
func DecodeAuthority(data []byte, now time.Time) (Authority, error) {
	if len(data) > MaxBytes {
		return Authority{}, ErrCredentials
	}
	certificate, rest := pem.Decode(data)
	if certificate == nil || certificate.Type != "CERTIFICATE" || len(certificate.Headers) != 0 {
		return Authority{}, ErrCredentials
	}
	key, tail := pem.Decode(rest)
	if key == nil || key.Type != "PRIVATE KEY" || len(key.Headers) != 0 || len(bytes.TrimSpace(tail)) != 0 {
		return Authority{}, ErrCredentials
	}
	pair, err := tls.X509KeyPair(data, data)
	if err != nil {
		return Authority{}, ErrCredentials
	}
	root, err := authorityCertificate(certificate.Bytes)
	if err != nil {
		return Authority{}, err
	}
	if now.Before(root.NotBefore) || !now.Before(root.NotAfter) {
		return Authority{}, ErrCredentials
	}
	private, ok := pair.PrivateKey.(ed25519.PrivateKey)
	if !ok {
		return Authority{}, ErrCredentials
	}
	return Authority{certificate: root, key: private}, nil
}

// Certificate returns the authority certificate as PEM, without its key.
func (a Authority) Certificate() []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: a.certificate.Raw})
}

// Issue signs a client and server leaf for public, valid on the given
// addresses and on loopback, which local clients of the node dial.
func (a Authority) Issue(public ed25519.PublicKey, addresses []netip.Addr, now time.Time) ([]byte, error) {
	if a.certificate == nil || len(public) != ed25519.PublicKeySize {
		return nil, ErrCredentials
	}
	ips := []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}
	for _, address := range addresses {
		if !address.IsValid() || address.Zone() != "" || address.IsUnspecified() {
			return nil, ErrCredentials
		}
		ip := net.IP(address.AsSlice())
		known := false
		for _, existing := range ips {
			known = known || existing.Equal(ip)
		}
		if !known {
			ips = append(ips, ip)
		}
	}
	expires := now.Add(LeafLifetime).Truncate(time.Second)
	if expires.After(a.certificate.NotAfter) {
		expires = a.certificate.NotAfter
	}
	number, err := serial()
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{SerialNumber: number, Subject: pkix.Name{CommonName: leafName},
		NotBefore: now.Add(-time.Minute), NotAfter: expires, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true, IPAddresses: ips}
	der, err := x509.CreateCertificate(rand.Reader, template, a.certificate, public, a.key)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), nil
}

// Credential joins a leaf and its private key into the runtime's credential file.
func Credential(leaf []byte, key ed25519.PrivateKey) ([]byte, error) {
	encoded, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	credential := append(bytes.Clone(leaf), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded})...)
	if _, err := tls.X509KeyPair(credential, credential); err != nil {
		return nil, ErrCredentials
	}
	return credential, nil
}

// Authorities decodes a pool of authority certificates.
func Authorities(data []byte) ([]*x509.Certificate, error) {
	if len(data) > MaxBytes {
		return nil, ErrCredentials
	}
	var result []*x509.Certificate
	for rest := data; len(bytes.TrimSpace(rest)) > 0; {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 || len(result) == maxAuthorities {
			return nil, ErrCredentials
		}
		root, err := authorityCertificate(block.Bytes)
		if err != nil {
			return nil, err
		}
		result = append(result, root)
	}
	if len(result) == 0 {
		return nil, ErrCredentials
	}
	return result, nil
}

// Pool merges authority pools, keeping each certificate once in first-seen order.
func Pool(pools ...[]byte) ([]byte, error) {
	var result []byte
	seen := map[string]bool{}
	for _, pool := range pools {
		roots, err := Authorities(pool)
		if err != nil {
			return nil, err
		}
		for _, root := range roots {
			if seen[string(root.Raw)] {
				continue
			}
			seen[string(root.Raw)] = true
			result = append(result, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: root.Raw})...)
		}
	}
	if len(seen) > maxAuthorities {
		return nil, ErrCredentials
	}
	return result, nil
}

// Verify checks that leaf carries public, chains to an authority of pool, is
// currently valid and serves both TLS roles.
func Verify(leaf, pool []byte, public ed25519.PublicKey, now time.Time) error {
	block, rest := pem.Decode(leaf)
	if len(leaf) > MaxBytes || block == nil || block.Type != "CERTIFICATE" || len(bytes.TrimSpace(rest)) != 0 {
		return ErrCredentials
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil || certificate.IsCA || certificate.PublicKeyAlgorithm != x509.Ed25519 {
		return ErrCredentials
	}
	key, ok := certificate.PublicKey.(ed25519.PublicKey)
	if !ok || !key.Equal(public) {
		return ErrCredentials
	}
	roots, err := Authorities(pool)
	if err != nil {
		return err
	}
	trusted := x509.NewCertPool()
	for _, root := range roots {
		trusted.AddCert(root)
	}
	for _, usage := range []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth} {
		if _, err := certificate.Verify(x509.VerifyOptions{Roots: trusted, CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{usage}}); err != nil {
			return ErrCredentials
		}
	}
	return nil
}
