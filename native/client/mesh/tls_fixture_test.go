//go:build meshclient

// SPDX-License-Identifier: MPL-2.0
// Certificate helper adapted from the runtime cluster stack tests.
package mesh

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"github.com/stretchr/testify/require"
	"github.com/wippyai/runtime/cluster/internode"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// clientTestTLSCerts creates a temporary CA and two leaf certificates signed by that CA.
// All certificate fixtures are created in t.TempDir() and are temporary only.
func clientTestTLSCerts(t *testing.T, nameA, nameB string) (internode.ManagerTLSConfig, internode.ManagerTLSConfig) {
	t.Helper()

	rootPub, rootPriv, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)

	now := time.Now()
	rootTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}

	rootDer, err := x509.CreateCertificate(rand.Reader, rootTemplate, rootTemplate, rootPub, rootPriv)
	require.NoError(t, err)

	dir := t.TempDir()
	caPath := filepath.Join(dir, "ca.pem")
	require.NoError(t, os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: rootDer}), 0600))

	issueLeaf := func(name string, serial int64) internode.ManagerTLSConfig {
		leafPub, leafPriv, err := ed25519.GenerateKey(rand.Reader)
		require.NoError(t, err)

		leafTemplate := &x509.Certificate{
			SerialNumber: big.NewInt(serial),
			NotBefore:    now.Add(-time.Minute),
			NotAfter:     now.Add(time.Hour),
			KeyUsage:     x509.KeyUsageDigitalSignature,
			ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
			IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
			DNSNames:     []string{"localhost"},
		}

		leafDer, err := x509.CreateCertificate(rand.Reader, leafTemplate, rootTemplate, leafPub, rootPriv)
		require.NoError(t, err)

		keyBytes, err := x509.MarshalPKCS8PrivateKey(leafPriv)
		require.NoError(t, err)

		certPath := filepath.Join(dir, name+".pem")
		keyPath := filepath.Join(dir, name+".key")

		require.NoError(t, os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDer}), 0600))
		require.NoError(t, os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyBytes}), 0600))

		return internode.ManagerTLSConfig{
			Enabled:  true,
			CAFile:   caPath,
			CertFile: certPath,
			KeyFile:  keyPath,
		}
	}

	return issueLeaf(nameA, 2), issueLeaf(nameB, 3)
}
