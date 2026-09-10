// SPDX-License-Identifier: MIT

package local

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	// DescriptorFileName is the standard filename for the published endpoint descriptor.
	DescriptorFileName = "local-admission.json"

	// LockFileName is the companion lock file used to serialize descriptor publication.
	LockFileName = ".local-admission.lock"

	// DescriptorVersion is the required schema version for endpoint descriptors.
	DescriptorVersion = 1

	// MaxDescriptorBytes limits the maximum size of a descriptor document to prevent denial-of-service.
	MaxDescriptorBytes = 16 * 1024
)

// Descriptor holds the validated parameters required for local physical-client mutual TLS rendezvous.
// Its String, GoString, and Format implementations redact the private key to prevent accidental secret leakage.
type Descriptor struct {
	Version        int
	RunID          string
	Endpoint       string
	CertificatePEM []byte
	PrivateKeyPEM  []byte
}

// String implements fmt.Stringer without exposing private key bytes.
func (d *Descriptor) String() string {
	if d == nil {
		return "<nil>"
	}
	return fmt.Sprintf("Descriptor(version=%d, run_id=%s, endpoint=%s)", d.Version, d.RunID, d.Endpoint)
}

// GoString implements fmt.GoStringer without exposing private key bytes.
func (d *Descriptor) GoString() string {
	if d == nil {
		return "<nil>"
	}
	return fmt.Sprintf("local.Descriptor{Version: %d, RunID: %q, Endpoint: %q}", d.Version, d.RunID, d.Endpoint)
}

// Format implements fmt.Formatter to guarantee private key material is never printed.
func (d Descriptor) Format(f fmt.State, c rune) {
	switch c {
	case 'v', 's', 'q':
		fmt.Fprintf(f, "Descriptor(version=%d, run_id=%s, endpoint=%s)", d.Version, d.RunID, d.Endpoint)
	default:
		fmt.Fprintf(f, "%%!%c(Descriptor=version=%d, run_id=%s, endpoint=%s)", c, d.Version, d.RunID, d.Endpoint)
	}
}

// persistedDescriptor is used for JSON serialization and token-level validation.
type persistedDescriptor struct {
	Version        int    `json:"version"`
	RunID          string `json:"run_id"`
	Endpoint       string `json:"endpoint"`
	CertificatePEM string `json:"certificate_pem"`
	PrivateKeyPEM  string `json:"private_key_pem"`
}

// ParseDescriptor decodes and strictly validates an endpoint descriptor from raw bytes.
//
// Validation invariants:
// - Payload must be non-empty, bounded by MaxDescriptorBytes, valid UTF-8, and contain no null bytes.
// - JSON must be a single object containing exactly the 5 required fields without unknown, duplicate, or null fields.
// - Version must be 1.
// - RunID must be non-empty and contains no whitespace or control characters.
// - Endpoint must be a literal loopback host:port address (e.g. 127.0.0.1:port or [::1]:port).
// - Certificate PEM must parse as an Ed25519 self-signed CA with localhost name and server+client auth usages.
// - Private Key PEM must parse as an Ed25519 PKCS#8 private key whose public key strictly matches the certificate.
// - Errors never include private key material.
func ParseDescriptor(data []byte) (*Descriptor, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("%w: descriptor document is empty", ErrInvalidDescriptor)
	}
	if int64(len(data)) > MaxDescriptorBytes {
		return nil, fmt.Errorf("%w: descriptor document exceeds size limit of %d bytes", ErrInvalidDescriptor, MaxDescriptorBytes)
	}
	if !utf8.Valid(data) {
		return nil, fmt.Errorf("%w: descriptor document is not valid UTF-8", ErrInvalidDescriptor)
	}
	if bytes.IndexByte(data, 0) != -1 {
		return nil, fmt.Errorf("%w: descriptor document contains null byte", ErrInvalidDescriptor)
	}

	rec, err := parseDescriptorJSON(data)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidDescriptor, err)
	}

	if rec.Version != DescriptorVersion {
		return nil, fmt.Errorf("%w: unsupported descriptor version %d (expected %d)", ErrInvalidDescriptor, rec.Version, DescriptorVersion)
	}

	if strings.TrimSpace(rec.RunID) == "" || strings.ContainsAny(rec.RunID, " \t\r\n\x00") || len(rec.RunID) < 8 || len(rec.RunID) > 128 {
		return nil, fmt.Errorf("%w: invalid run_id", ErrInvalidDescriptor)
	}

	if err := validateEndpoint(rec.Endpoint); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidDescriptor, err)
	}

	cert, certPub, err := validateCertificatePEM([]byte(rec.CertificatePEM))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidDescriptor, err)
	}

	if err := validatePrivateKeyPEM([]byte(rec.PrivateKeyPEM), certPub); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidDescriptor, err)
	}

	_ = cert // certificate verified

	return &Descriptor{
		Version:        rec.Version,
		RunID:          rec.RunID,
		Endpoint:       rec.Endpoint,
		CertificatePEM: []byte(rec.CertificatePEM),
		PrivateKeyPEM:  []byte(rec.PrivateKeyPEM),
	}, nil
}

// Encode serializes the descriptor to indented JSON bytes terminated by a newline.
func (d *Descriptor) Encode() ([]byte, error) {
	if d == nil {
		return nil, errors.New("cannot encode nil descriptor")
	}
	rec := persistedDescriptor{
		Version:        d.Version,
		RunID:          d.RunID,
		Endpoint:       d.Endpoint,
		CertificatePEM: string(d.CertificatePEM),
		PrivateKeyPEM:  string(d.PrivateKeyPEM),
	}
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal descriptor: %w", err)
	}
	return append(data, '\n'), nil
}

func parseDescriptorJSON(data []byte) (*persistedDescriptor, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	start, err := dec.Token()
	if err != nil || start != json.Delim('{') {
		return nil, errors.New("descriptor document must be a JSON object")
	}

	allowedKeys := map[string]bool{
		"version":         true,
		"run_id":          true,
		"endpoint":        true,
		"certificate_pem": true,
		"private_key_pem": true,
	}

	seen := make(map[string]bool)
	var rec persistedDescriptor

	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, errors.New("malformed JSON in descriptor document")
		}
		key, ok := tok.(string)
		if !ok {
			return nil, errors.New("descriptor object key must be a string")
		}
		if !allowedKeys[key] {
			return nil, fmt.Errorf("descriptor contains unknown field %q", key)
		}
		if seen[key] {
			return nil, fmt.Errorf("descriptor contains duplicate field %q", key)
		}
		seen[key] = true

		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, errors.New("malformed JSON value in descriptor")
		}
		rawTrimmed := bytes.TrimSpace(raw)
		if bytes.Equal(rawTrimmed, []byte("null")) {
			return nil, fmt.Errorf("descriptor field %q cannot be null", key)
		}

		switch key {
		case "version":
			if bytes.ContainsAny(rawTrimmed, ".eE") {
				return nil, errors.New("descriptor field 'version' must be an integer")
			}
			if err := json.Unmarshal(rawTrimmed, &rec.Version); err != nil {
				return nil, errors.New("descriptor field 'version' must be an integer")
			}
		case "run_id":
			if err := json.Unmarshal(rawTrimmed, &rec.RunID); err != nil {
				return nil, errors.New("descriptor field 'run_id' must be a string")
			}
		case "endpoint":
			if err := json.Unmarshal(rawTrimmed, &rec.Endpoint); err != nil {
				return nil, errors.New("descriptor field 'endpoint' must be a string")
			}
		case "certificate_pem":
			if err := json.Unmarshal(rawTrimmed, &rec.CertificatePEM); err != nil {
				return nil, errors.New("descriptor field 'certificate_pem' must be a string")
			}
		case "private_key_pem":
			if err := json.Unmarshal(rawTrimmed, &rec.PrivateKeyPEM); err != nil {
				return nil, errors.New("descriptor field 'private_key_pem' must be a string")
			}
		}
	}

	end, err := dec.Token()
	if err != nil || end != json.Delim('}') {
		return nil, errors.New("malformed JSON end delimiter in descriptor document")
	}

	var trailing json.RawMessage
	if err := dec.Decode(&trailing); err != io.EOF {
		return nil, errors.New("descriptor document has trailing content")
	}

	for k := range allowedKeys {
		if !seen[k] {
			return nil, fmt.Errorf("descriptor missing required field %q", k)
		}
	}

	return &rec, nil
}

func validateEndpoint(endpoint string) error {
	host, portStr, err := net.SplitHostPort(endpoint)
	if err != nil {
		return errors.New("endpoint is not a valid host:port string")
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 || strconv.Itoa(port) != portStr {
		return errors.New("endpoint port is invalid")
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return errors.New("endpoint host must be a literal IP address")
	}
	if !ip.IsLoopback() {
		return errors.New("endpoint host must be a loopback address")
	}
	return nil
}

func validateCertificatePEM(pemBytes []byte) (*x509.Certificate, ed25519.PublicKey, error) {
	block, rest := pem.Decode(pemBytes)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, nil, errors.New("certificate PEM is missing or invalid")
	}
	if len(bytes.TrimSpace(rest)) > 0 {
		return nil, nil, errors.New("certificate PEM has trailing content")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, nil, errors.New("x509 certificate parsing failed")
	}
	if !cert.IsCA {
		return nil, nil, errors.New("certificate must be a CA")
	}
	if cert.KeyUsage&(x509.KeyUsageDigitalSignature|x509.KeyUsageCertSign) != (x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign) {
		return nil, nil, errors.New("certificate missing required key usage")
	}
	var hasServerAuth, hasClientAuth bool
	for _, ku := range cert.ExtKeyUsage {
		if ku == x509.ExtKeyUsageServerAuth {
			hasServerAuth = true
		}
		if ku == x509.ExtKeyUsageClientAuth {
			hasClientAuth = true
		}
	}
	if !hasServerAuth || !hasClientAuth {
		return nil, nil, errors.New("certificate missing required extended key usages")
	}
	var hasLocalhost bool
	for _, name := range cert.DNSNames {
		if name == "localhost" {
			hasLocalhost = true
			break
		}
	}
	if !hasLocalhost {
		return nil, nil, errors.New("certificate missing localhost DNS name")
	}
	certPub, ok := cert.PublicKey.(ed25519.PublicKey)
	if !ok || len(certPub) != ed25519.PublicKeySize {
		return nil, nil, errors.New("certificate public key must be Ed25519")
	}
	if err := cert.CheckSignature(cert.SignatureAlgorithm, cert.RawTBSCertificate, cert.Signature); err != nil {
		return nil, nil, errors.New("certificate signature verification failed")
	}
	return cert, certPub, nil
}

func validatePrivateKeyPEM(pemBytes []byte, certPub ed25519.PublicKey) error {
	block, rest := pem.Decode(pemBytes)
	if block == nil || block.Type != "PRIVATE KEY" {
		return errors.New("private key PEM is missing or invalid")
	}
	if len(bytes.TrimSpace(rest)) > 0 {
		return errors.New("private key PEM has trailing content")
	}
	parsedKey, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return errors.New("private key is not valid PKCS#8")
	}
	privKey, ok := parsedKey.(ed25519.PrivateKey)
	if !ok || len(privKey) != ed25519.PrivateKeySize {
		return errors.New("private key must be Ed25519")
	}
	derivedPub, ok := privKey.Public().(ed25519.PublicKey)
	if !ok || !bytes.Equal(derivedPub, certPub) {
		return errors.New("private key does not correspond to certificate public key")
	}
	return nil
}
