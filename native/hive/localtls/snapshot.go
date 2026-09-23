//go:build meshclient

// SPDX-License-Identifier: MIT

package localtls

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
	"github.com/wippyai/runtime/cluster/internode"
)

const (
	maxJoinedSourceFileBytes = 32 * 1024
	maxJoinedInputBytes      = 3 * maxJoinedSourceFileBytes
	joinedMarkerType         = "BEE JOINED LOCAL TLS SNAPSHOT"
	joinedMarkerVersion      = "1"
	maxJoinedChainCerts      = 8
)

type joinedSnapshot struct {
	chain     []*x509.Certificate
	roots     []*x509.Certificate
	keyPEM    []byte
	expires   time.Time
	execution string
}

// SnapshotJoined copies a joined Hive owner's selected TLS identity into its
// protected, execution-specific rendezvous directory. The copy is immutable for
// that execution, just like credentials created by Prepare and PrepareShared.
// Its effective deadline is the earliest of the certificate chain, configured
// trust roots, and 30 days from this snapshot. Load returns that same deadline.
//
// The source is host-selected configuration. It must contain bounded PEM files
// for a TLS leaf and optional intermediates, its private key, and one or more CA
// certificates. The leaf must verify for both TLS roles and both loopback IPs;
// snapshotting does not alter enrollment or grant application permissions.
func SnapshotJoined(ctx context.Context, directory, execution string, source internode.ManagerTLSConfig) (Credentials, error) {
	if ctx == nil || !validExecution(execution) || !source.Enabled {
		return Credentials{}, ErrCredentials
	}
	file, err := privatefile.New(directory, document(execution), ".local-tls-"+execution+".lock")
	if err != nil {
		return Credentials{}, err
	}
	var expires time.Time
	err = file.ReadModifyWrite(ctx, maxJoinedDocumentBytes, func(existing []byte) ([]byte, error) {
		now := time.Now()
		if existing != nil {
			snapshot, err := decodeJoinedSnapshot(existing)
			if err != nil {
				return nil, ErrCredentials
			}
			if err := validateJoinedSnapshot(snapshot, execution, now); err != nil {
				return nil, err
			}
			expires = snapshot.expires
			return nil, nil
		}
		data, snapshot, err := createJoinedSnapshot(ctx, execution, source, now)
		if err != nil {
			return nil, err
		}
		expires = snapshot.expires
		return data, nil
	})
	if err != nil {
		return Credentials{}, err
	}
	return config(directory, execution, expires), nil
}

func createJoinedSnapshot(ctx context.Context, execution string, source internode.ManagerTLSConfig, now time.Time) ([]byte, joinedSnapshot, error) {
	if source.CertFile == "" || source.KeyFile == "" || source.CAFile == "" {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	certificatePEM, err := readSource(ctx, source.CertFile)
	if err != nil {
		return nil, joinedSnapshot{}, err
	}
	keyPEM, err := readSource(ctx, source.KeyFile)
	if err != nil {
		return nil, joinedSnapshot{}, err
	}
	caPEM, err := readSource(ctx, source.CAFile)
	if err != nil {
		return nil, joinedSnapshot{}, err
	}
	if len(certificatePEM)+len(keyPEM)+len(caPEM) > maxJoinedInputBytes {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	chain, canonicalCerts, err := parseCertificates(certificatePEM, maxJoinedChainCerts)
	if err != nil || len(chain) == 0 {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	_, canonicalKey, err := parsePrivateKey(keyPEM)
	if err != nil {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	roots, canonicalRoots, err := parseCertificates(caPEM, maxJoinedChainCerts)
	if err != nil || len(roots) == 0 {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	if err := validateJoinedMaterial(canonicalCerts, canonicalKey, chain, roots, now); err != nil {
		return nil, joinedSnapshot{}, err
	}
	expires := now.Add(maxLifetime).Truncate(time.Second)
	for _, certificate := range append(append([]*x509.Certificate(nil), chain...), roots...) {
		if certificate.NotAfter.Before(expires) {
			expires = certificate.NotAfter.Truncate(time.Second)
		}
	}
	if !expires.After(now) {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	snapshot := joinedSnapshot{chain: chain, roots: roots, keyPEM: canonicalKey, expires: expires, execution: execution}
	var bundle bytes.Buffer
	bundle.Write(canonicalCerts)
	bundle.Write(canonicalKey)
	bundle.Write(canonicalRoots)
	bundle.Write(pem.EncodeToMemory(&pem.Block{Type: joinedMarkerType, Bytes: markerPayload(execution, expires)}))
	if bundle.Len() > maxJoinedDocumentBytes {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	// Check the exact artifact with the same key-pair decoder used by runtime TLS.
	if _, err := tls.X509KeyPair(bundle.Bytes(), bundle.Bytes()); err != nil {
		return nil, joinedSnapshot{}, ErrCredentials
	}
	return bundle.Bytes(), snapshot, nil
}

func readSource(ctx context.Context, path string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if len(path) == 0 || len(path) > 4096 {
		return nil, ErrCredentials
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		return nil, ErrCredentials
	}
	data, err := io.ReadAll(io.LimitReader(file, maxJoinedSourceFileBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) == 0 || len(data) > maxJoinedSourceFileBytes {
		return nil, ErrCredentials
	}
	return data, ctx.Err()
}

func parseCertificates(data []byte, limit int) ([]*x509.Certificate, []byte, error) {
	var result []*x509.Certificate
	var canonical bytes.Buffer
	for len(bytes.TrimSpace(data)) != 0 {
		block, rest, err := nextPEM(data)
		if err != nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 || len(result) >= limit {
			return nil, nil, ErrCredentials
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, nil, ErrCredentials
		}
		result = append(result, certificate)
		canonical.Write(pem.EncodeToMemory(block))
		data = rest
	}
	return result, canonical.Bytes(), nil
}

func parsePrivateKey(data []byte) (*pem.Block, []byte, error) {
	block, rest, err := nextPEM(data)
	if err != nil || len(block.Headers) != 0 || !strings.HasSuffix(block.Type, "PRIVATE KEY") || len(bytes.TrimSpace(rest)) != 0 {
		return nil, nil, ErrCredentials
	}
	return block, pem.EncodeToMemory(block), nil
}

func nextPEM(data []byte) (*pem.Block, []byte, error) {
	data = bytes.TrimLeft(data, " \t\r\n")
	if !bytes.HasPrefix(data, []byte("-----BEGIN ")) {
		return nil, nil, ErrCredentials
	}
	block, rest := pem.Decode(data)
	if block == nil {
		return nil, nil, ErrCredentials
	}
	return block, rest, nil
}

func validateJoinedMaterial(certificatePEM, keyPEM []byte, chain, roots []*x509.Certificate, now time.Time) error {
	pair, err := tls.X509KeyPair(certificatePEM, keyPEM)
	if err != nil || len(pair.Certificate) != len(chain) {
		return ErrCredentials
	}
	leaf := chain[0]
	if leaf.IsCA || now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) || leaf.NotAfter.Sub(now) <= 0 {
		return ErrCredentials
	}
	for _, address := range []string{"127.0.0.1", "::1"} {
		if err := leaf.VerifyHostname(address); err != nil {
			return ErrCredentials
		}
	}
	rootPool := x509.NewCertPool()
	for _, root := range roots {
		if !root.IsCA || !root.BasicConstraintsValid || root.KeyUsage&x509.KeyUsageCertSign == 0 ||
			now.Before(root.NotBefore) || !now.Before(root.NotAfter) {
			return ErrCredentials
		}
		rootPool.AddCert(root)
	}
	intermediatePool := x509.NewCertPool()
	for _, intermediate := range chain[1:] {
		if !intermediate.IsCA || !intermediate.BasicConstraintsValid || intermediate.KeyUsage&x509.KeyUsageCertSign == 0 {
			return ErrCredentials
		}
		intermediatePool.AddCert(intermediate)
	}
	for _, usage := range []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth} {
		if _, err := leaf.Verify(x509.VerifyOptions{Roots: rootPool, Intermediates: intermediatePool, CurrentTime: now, KeyUsages: []x509.ExtKeyUsage{usage}}); err != nil {
			return ErrCredentials
		}
	}
	return nil
}

func markerPayload(execution string, expires time.Time) []byte {
	return []byte(joinedMarkerVersion + "\n" + execution + "\n" + strconv.FormatInt(expires.Unix(), 10) + "\n")
}

func hasJoinedMarker(data []byte) bool {
	return bytes.Contains(data, []byte("-----BEGIN "+joinedMarkerType+"-----"))
}

func decodeJoinedSnapshot(data []byte) (joinedSnapshot, error) {
	var result joinedSnapshot
	var blockBytes [][]byte
	var blockTypes []string
	remaining := data
	for len(bytes.TrimSpace(remaining)) != 0 {
		block, rest, err := nextPEM(remaining)
		if err != nil || len(block.Headers) != 0 {
			return joinedSnapshot{}, ErrCredentials
		}
		blockBytes = append(blockBytes, append([]byte(nil), block.Bytes...))
		blockTypes = append(blockTypes, block.Type)
		remaining = rest
	}
	var canonical bytes.Buffer
	for index, blockType := range blockTypes {
		canonical.Write(pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: blockBytes[index]}))
	}
	if !bytes.Equal(data, canonical.Bytes()) {
		return joinedSnapshot{}, ErrCredentials
	}
	state := "chain"
	markerCount, keyCount := 0, 0
	for index, blockType := range blockTypes {
		der := blockBytes[index]
		switch {
		case blockType == "CERTIFICATE" && state == "chain":
			certificate, err := x509.ParseCertificate(der)
			if err != nil || len(result.chain) >= maxJoinedChainCerts {
				return joinedSnapshot{}, ErrCredentials
			}
			result.chain = append(result.chain, certificate)
		case strings.HasSuffix(blockType, "PRIVATE KEY") && state == "chain":
			state = "roots"
			keyCount++
			result.keyPEM = pem.EncodeToMemory(&pem.Block{Type: blockType, Bytes: der})
		case blockType == "CERTIFICATE" && state == "roots":
			certificate, err := x509.ParseCertificate(der)
			if err != nil || len(result.roots) >= maxJoinedChainCerts {
				return joinedSnapshot{}, ErrCredentials
			}
			result.roots = append(result.roots, certificate)
		case blockType == joinedMarkerType && state == "roots":
			if markerCount != 0 || index != len(blockTypes)-1 {
				return joinedSnapshot{}, ErrCredentials
			}
			markerCount++
			result.execution, result.expires = parseMarker(der)
			if result.execution == "" || result.expires.IsZero() {
				return joinedSnapshot{}, ErrCredentials
			}
		default:
			return joinedSnapshot{}, ErrCredentials
		}
	}
	if len(result.chain) == 0 || len(result.roots) == 0 || keyCount != 1 || markerCount != 1 || state != "roots" {
		return joinedSnapshot{}, ErrCredentials
	}
	return result, nil
}

func parseMarker(data []byte) (string, time.Time) {
	fields := strings.Split(string(data), "\n")
	if len(fields) != 4 || fields[0] != joinedMarkerVersion || !validExecution(fields[1]) || fields[3] != "" {
		return "", time.Time{}
	}
	seconds, err := strconv.ParseInt(fields[2], 10, 64)
	if err != nil || seconds <= 0 {
		return "", time.Time{}
	}
	return fields[1], time.Unix(seconds, 0).UTC()
}

func validateJoinedSnapshot(snapshot joinedSnapshot, execution string, now time.Time) error {
	if snapshot.execution != execution {
		return ErrExecution
	}
	chainPEM := encodeCertificates(snapshot.chain)
	if err := validateJoinedMaterial(chainPEM, snapshot.keyPEM, snapshot.chain, snapshot.roots, now); err != nil {
		return err
	}
	deadline := now.Add(maxLifetime)
	if !snapshot.expires.After(now) || snapshot.expires.After(deadline) {
		return ErrCredentials
	}
	for _, certificate := range append(append([]*x509.Certificate(nil), snapshot.chain...), snapshot.roots...) {
		if snapshot.expires.After(certificate.NotAfter) {
			return ErrCredentials
		}
	}
	return nil
}

func encodeCertificates(certificates []*x509.Certificate) []byte {
	var result bytes.Buffer
	for _, certificate := range certificates {
		result.Write(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate.Raw}))
	}
	return result.Bytes()
}
