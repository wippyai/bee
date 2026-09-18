// SPDX-License-Identifier: MIT

// Package identity provides a small, durable machine identity owner.
//
// Authority and Boundaries:
// Machine identity relies on native OS-user filesystem authority (owner-only permissions)
// to protect local private keys. It makes no false sandbox claims: any process
// running as the same OS user has equal access to these files. Machine identity
// identifies a machine independently of its Hive enrollment; it never doubles as a runtime-node
// identity (e.g. relay.node_name or cluster.name) or a workspace identity.
package identity

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/wippyai/bee/native/internal/privatefile"
)

const (
	// DomainSeparationTag distinguishes machine ID derivation from other ID domains.
	DomainSeparationTag = "bee-machine-identity:v1\x00"

	// IdentityVersion is the current schema version for persisted machine identity files.
	IdentityVersion = 1

	// IdentityKeyType is the expected key algorithm type.
	IdentityKeyType = "ed25519"

	// IdentityFileName is the filename under the supplied private directory where
	// the machine identity is durably persisted.
	IdentityFileName = "identity.json"

	// LockFileName is the filename used for exclusive file locking.
	LockFileName = ".identity.lock"
)

// Identity is an immutable, validated machine identity containing an Ed25519 keypair
// and a stable opaque machine ID.
type Identity struct {
	id         string
	publicKey  ed25519.PublicKey
	privateKey ed25519.PrivateKey
}

// ID returns the stable opaque machine identifier derived from the public key
// with explicit domain separation. It begins with the prefix "mid_".
func (i *Identity) ID() string {
	return i.id
}

// PublicKey returns a copy of the Ed25519 public key.
func (i *Identity) PublicKey() ed25519.PublicKey {
	cp := make(ed25519.PublicKey, len(i.publicKey))
	copy(cp, i.publicKey)
	return cp
}

// Sign produces an Ed25519 signature of the provided message using the machine's private key.
func (i *Identity) Sign(message []byte) []byte {
	return ed25519.Sign(i.privateKey, message)
}

// String implements fmt.Stringer without exposing private key bytes.
func (i *Identity) String() string {
	if i == nil {
		return "<nil>"
	}
	return fmt.Sprintf("Identity(%s)", i.id)
}

// GoString implements fmt.GoStringer without exposing private key bytes.
func (i *Identity) GoString() string {
	if i == nil {
		return "<nil>"
	}
	return fmt.Sprintf("identity.Identity{id: %q}", i.id)
}

// Format implements fmt.Formatter to guarantee private bytes are never printed
// under any format verb (including %+v and %#v).
func (i Identity) Format(f fmt.State, c rune) {
	switch c {
	case 'v', 's', 'q':
		fmt.Fprintf(f, "Identity(%s)", i.id)
	default:
		fmt.Fprintf(f, "%%!%c(Identity=%s)", c, i.id)
	}
}

// MarshalJSON ensures that only public identity attributes are exported to JSON.
func (i *Identity) MarshalJSON() ([]byte, error) {
	if i == nil {
		return []byte("null"), nil
	}
	return json.Marshal(map[string]string{
		"id":         i.id,
		"public_key": hex.EncodeToString(i.publicKey),
	})
}

// DeriveMachineID deterministically computes a stable, opaque machine ID from an
// Ed25519 public key using an explicit domain separator.
func DeriveMachineID(pubKey ed25519.PublicKey) string {
	h := sha256.New()
	h.Write([]byte(DomainSeparationTag))
	h.Write(pubKey)
	return "mid_" + hex.EncodeToString(h.Sum(nil))
}

type persistedIdentity struct {
	Version    int    `json:"version"`
	KeyType    string `json:"key_type"`
	MachineID  string `json:"machine_id"`
	PublicKey  string `json:"public_key"`
	PrivateKey string `json:"private_key"`
}

// OpenOrCreate opens an existing validated machine identity from directory, or creates
// and atomically persists a fresh versioned Ed25519 identity if none exists.
//
// Concurrency & Safety:
//   - Uses an OS-backed file lock contending on a stable lock inode (.identity.lock).
//   - Context deadline/cancellation is honored while waiting for locks, releasing all handles.
//   - Existing identity files that are corrupt, unsupported, non-regular, or have insecure
//     permissions fail closed immediately; keys are NEVER regenerated or overwritten.
//   - Creation uses atomic temporary write, fsync, and rename with cleanup on failure.
func OpenOrCreate(ctx context.Context, directory string) (ident *Identity, retErr error) {
	if ctx == nil {
		return nil, errors.New("context is required")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(directory) == "" {
		return nil, errors.New("identity directory path is required")
	}

	cleanDir := filepath.Clean(directory)
	pf, err := privatefile.New(cleanDir, IdentityFileName, LockFileName)
	if err != nil {
		return nil, err
	}

	const maxIdentityBytes = 4096
	var loaded *Identity
	err = pf.ReadModifyWrite(ctx, maxIdentityBytes, func(existing []byte) ([]byte, error) {
		if existing != nil {
			// File already exists: must validate and load. Fails closed on any error.
			id, err := loadIdentityBytes(existing)
			if err != nil {
				return nil, err
			}
			loaded = id
			return nil, nil
		}

		// File does not exist: create atomically.
		id, raw, err := createIdentityBytes()
		if err != nil {
			return nil, err
		}
		loaded = id
		return raw, nil
	})
	if err != nil {
		var syncErr *privatefile.PublishedSyncError
		if errors.As(err, &syncErr) {
			return nil, fmt.Errorf("identity published but directory sync failed: %w", syncErr.Err)
		}
		return nil, err
	}

	return loaded, nil
}

func loadIdentityBytes(data []byte) (*Identity, error) {
	var rec persistedIdentity
	if !uniqueIdentityFields(data) {
		return nil, errors.New("identity document has invalid or duplicate fields")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&rec); err != nil {
		return nil, errors.New("invalid identity document")
	}
	var trailing json.RawMessage
	if err := dec.Decode(&trailing); err != io.EOF {
		return nil, errors.New("identity document has trailing content")
	}

	if rec.Version != IdentityVersion {
		return nil, fmt.Errorf("unsupported identity version %d (expected %d)", rec.Version, IdentityVersion)
	}
	if rec.KeyType != IdentityKeyType {
		return nil, errors.New("unsupported identity key type")
	}

	pubBytes, err := decodeKeyBytes(rec.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("decode public key: %w", err)
	}
	if len(pubBytes) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid public key size %d", len(pubBytes))
	}

	privBytes, err := decodeKeyBytes(rec.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("decode private key: %w", err)
	}
	if len(privBytes) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("invalid private key size %d", len(privBytes))
	}

	privKey := ed25519.PrivateKey(privBytes)
	if !bytes.Equal(ed25519.NewKeyFromSeed(privKey.Seed()), privKey) {
		return nil, errors.New("private key is inconsistent with its seed")
	}
	derivedPub := privKey.Public().(ed25519.PublicKey)
	if !bytes.Equal(derivedPub, pubBytes) {
		return nil, errors.New("public key does not correspond to private key")
	}

	derivedID := DeriveMachineID(pubBytes)
	if rec.MachineID != derivedID {
		return nil, errors.New("machine ID is missing or inconsistent with public key")
	}

	return &Identity{
		id:         derivedID,
		publicKey:  pubBytes,
		privateKey: privKey,
	}, nil
}

// encoding/json otherwise silently accepts the last occurrence of a field,
// including a second schema version or private key.
func uniqueIdentityFields(data []byte) bool {
	dec := json.NewDecoder(bytes.NewReader(data))
	start, err := dec.Token()
	if err != nil || start != json.Delim('{') {
		return false
	}
	seen := make(map[string]bool)
	for dec.More() {
		token, err := dec.Token()
		if err != nil {
			return false
		}
		key, ok := token.(string)
		if !ok || seen[key] {
			return false
		}
		seen[key] = true
		var value json.RawMessage
		if dec.Decode(&value) != nil {
			return false
		}
	}
	_, err = dec.Token()
	return err == nil
}

func createIdentityBytes() (*Identity, []byte, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate ed25519 key: %w", err)
	}

	mid := DeriveMachineID(pub)
	rec := persistedIdentity{
		Version:    IdentityVersion,
		KeyType:    IdentityKeyType,
		MachineID:  mid,
		PublicKey:  hex.EncodeToString(pub),
		PrivateKey: hex.EncodeToString(priv),
	}

	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return nil, nil, fmt.Errorf("marshal identity: %w", err)
	}
	data = append(data, '\n')

	return &Identity{
		id:         mid,
		publicKey:  pub,
		privateKey: priv,
	}, data, nil
}

func decodeKeyBytes(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if b, err := hex.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.RawStdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	if b, err := base64.StdEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return nil, errors.New("key string is not valid hex or base64")
}
