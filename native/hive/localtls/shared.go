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
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"net"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
)

// PrepareShared issues an execution credential under the same-account Hive
// authority. The host selects both directories. This grants transport trust,
// not membership identity or permission to operate another workspace.
func PrepareShared(ctx context.Context, directory, execution string, expires time.Time, authorityDirectory string) (Credentials, error) {
	return prepareShared(ctx, directory, execution, expires, authorityDirectory, time.Now())
}

func prepareShared(ctx context.Context, directory, execution string, expires time.Time, authorityDirectory string, now time.Time) (Credentials, error) {
	expires = expires.Truncate(time.Second)
	if !validExecution(execution) || !expires.After(now) || expires.Sub(now) > maxLifetime {
		return Credentials{}, ErrCredentials
	}
	authority, err := privatefile.New(authorityDirectory, "authority.pem", ".authority.lock")
	if err != nil {
		return Credentials{}, err
	}
	var root *x509.Certificate
	var signer ed25519.PrivateKey
	err = authority.ReadModifyWrite(ctx, maxBytes, func(existing []byte) ([]byte, error) {
		if existing != nil {
			root, signer, err = decodeAuthority(existing)
			if err != nil {
				return nil, err
			}
			if now.Before(root.NotBefore) {
				return nil, ErrCredentials
			}
			if now.Before(root.NotAfter) {
				return nil, nil
			}
			// Every issued owner deadline is capped by this expiry. Rotate only once
			// no credential under the old authority can still be valid.
		}
		document, generateError := generateAuthority(now)
		if generateError != nil {
			return nil, generateError
		}
		root, signer, err = decodeAuthority(document)
		return document, err
	})
	if err != nil {
		return Credentials{}, err
	}
	if expires.After(root.NotAfter) {
		expires = root.NotAfter
	}
	file, err := privatefile.New(directory, document(execution), ".local-tls-"+execution+".lock")
	if err != nil {
		return Credentials{}, err
	}
	err = file.ReadModifyWrite(ctx, maxBytes, func(existing []byte) ([]byte, error) {
		if existing != nil {
			certificate, decodeError := decode(existing)
			if decodeError != nil {
				return nil, decodeError
			}
			if err := validate(certificate, execution, now); err != nil {
				return nil, err
			}
			if err := certificate.CheckSignatureFrom(root); err != nil {
				return nil, ErrCredentials
			}
			expires = certificate.NotAfter
			return nil, nil
		}
		public, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return nil, err
		}
		serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
		if err != nil {
			return nil, err
		}
		serial.Add(serial, big.NewInt(1))
		leaf := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Bee local mesh", SerialNumber: execution},
			NotBefore: now.Add(-time.Minute), NotAfter: expires, KeyUsage: x509.KeyUsageDigitalSignature,
			ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true,
			IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}}
		der, err := x509.CreateCertificate(rand.Reader, leaf, root, public, signer)
		if err != nil {
			return nil, err
		}
		key, err := x509.MarshalPKCS8PrivateKey(private)
		if err != nil {
			return nil, err
		}
		result := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
		result = append(result, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: root.Raw})...)
		return append(result, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key})...), nil
	})
	if err != nil {
		return Credentials{}, err
	}
	return config(directory, execution, expires), nil
}

func generateAuthority(now time.Time) ([]byte, error) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	var identity [16]byte
	if _, err := rand.Read(identity[:]); err != nil {
		return nil, err
	}
	serial := new(big.Int).SetBytes(identity[:])
	serial.Add(serial, big.NewInt(1))
	root := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "Bee local Hive authority", SerialNumber: hex.EncodeToString(identity[:])},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(maxLifetime).Truncate(time.Second),
		IsCA: true, BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(rand.Reader, root, root, public, private)
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

func authorityCertificate(der []byte) (*x509.Certificate, error) {
	root, err := x509.ParseCertificate(der)
	if err != nil || !root.IsCA || !root.BasicConstraintsValid || root.PublicKeyAlgorithm != x509.Ed25519 ||
		root.KeyUsage != x509.KeyUsageCertSign|x509.KeyUsageDigitalSignature || !root.MaxPathLenZero || root.MaxPathLen != 0 ||
		root.Subject.CommonName != "Bee local Hive authority" || !validExecution(root.Subject.SerialNumber) {
		return nil, ErrCredentials
	}
	if err := root.CheckSignatureFrom(root); err != nil {
		return nil, ErrCredentials
	}
	return root, nil
}

func decodeAuthority(data []byte) (*x509.Certificate, ed25519.PrivateKey, error) {
	certificate, rest := pem.Decode(data)
	if certificate == nil || certificate.Type != "CERTIFICATE" || len(certificate.Headers) != 0 {
		return nil, nil, ErrCredentials
	}
	key, tail := pem.Decode(rest)
	if key == nil || key.Type != "PRIVATE KEY" || len(key.Headers) != 0 || len(tail) != 0 {
		return nil, nil, ErrCredentials
	}
	if !bytes.Equal(data, append(pem.EncodeToMemory(certificate), pem.EncodeToMemory(key)...)) {
		return nil, nil, ErrCredentials
	}
	pair, err := tls.X509KeyPair(data, data)
	if err != nil {
		return nil, nil, ErrCredentials
	}
	root, err := authorityCertificate(certificate.Bytes)
	if err != nil {
		return nil, nil, err
	}
	private, ok := pair.PrivateKey.(ed25519.PrivateKey)
	if !ok {
		return nil, nil, ErrCredentials
	}
	return root, private, nil
}
