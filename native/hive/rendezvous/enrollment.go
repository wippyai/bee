// SPDX-License-Identifier: MIT

package rendezvous

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"

	"github.com/wippyai/bee/native/internal/privatefile"
)

const (
	EnrollmentFileName = "local-enrollment.json"
	MaxLocalPeers      = 128
	maxEnrollmentBytes = 64 * 1024
)

var (
	ErrEnrollment        = errors.New("invalid local Bee enrollment")
	ErrOwnerChanged      = errors.New("Bee owner execution changed")
	ErrPeerConflict      = errors.New("Bee client identity already has a different key")
	ErrPeerCapacity      = errors.New("Bee local client enrollment is full")
	ErrBootstrapConflict = errors.New("Bee owner execution already has a different bootstrap key")
)

type enrollmentRecord struct {
	Version   int               `json:"version"`
	Execution string            `json:"execution"`
	Secret    string            `json:"secret"`
	Peers     map[string]string `json:"peers"`
	Slots     map[string]int    `json:"slots"`
}

// Enrollment is native OS-user-authorized bootstrap storage for one owner
// execution. It never authorizes workspace operations or remote machine joins.
type Enrollment struct {
	file      *privatefile.File
	directory string
}

// Snapshot hides and redacts the gossip secret. Key access returns copies.
type Snapshot struct {
	execution string
	secret    []byte
	peers     map[string]ed25519.PublicKey
}

func (s Snapshot) GossipKey() []byte { return bytes.Clone(s.secret) }
func (s Snapshot) PeerKey(node string) (ed25519.PublicKey, bool) {
	key, ok := s.peers[node]
	return bytes.Clone(key), ok
}
func (s Snapshot) Format(out fmt.State, _ rune) {
	_, _ = fmt.Fprintf(out, "BeeEnrollment(execution=%s, peers=%d)", s.execution, len(s.peers))
}

func NewEnrollment(directory string) (*Enrollment, error) {
	file, err := privatefile.New(directory, EnrollmentFileName, ".local-enrollment.lock")
	if err != nil {
		return nil, err
	}
	return &Enrollment{file: file, directory: directory}, nil
}

func validExecution(value string) bool {
	if len(value) != 32 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func validPeer(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if r < 33 || r > 126 {
			return false
		}
	}
	return true
}

// enrollmentObject rejects duplicate, null and unknown fields before decoding
// typed values. A nil schema permits peer IDs as keys, subject to the count bound.
func enrollmentObject(data []byte, limit int, schema map[string]bool) (map[string]json.RawMessage, error) {
	if len(data) == 0 || len(data) > maxEnrollmentBytes || !utf8.Valid(data) {
		return nil, ErrEnrollment
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	first, err := dec.Token()
	if err != nil || first != json.Delim('{') {
		return nil, ErrEnrollment
	}
	fields := make(map[string]json.RawMessage)
	for dec.More() {
		token, err := dec.Token()
		name, ok := token.(string)
		if err != nil || !ok || fields[name] != nil || len(fields) >= limit || schema != nil && !schema[name] {
			return nil, ErrEnrollment
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return nil, ErrEnrollment
		}
		fields[name] = raw
	}
	last, err := dec.Token()
	if err != nil || last != json.Delim('}') || schema != nil && len(fields) != len(schema) {
		return nil, ErrEnrollment
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, ErrEnrollment
	}
	return fields, nil
}

func decodeEnrollment(data []byte) (enrollmentRecord, error) {
	fields, err := enrollmentObject(data, 5, nil)
	if err != nil {
		return enrollmentRecord{}, err
	}
	var version int
	if err := json.Unmarshal(fields["version"], &version); err != nil {
		return enrollmentRecord{}, ErrEnrollment
	}
	required := map[string]bool{"version": true, "execution": true, "secret": true, "peers": true}
	if version == 2 {
		required["slots"] = true
	} else if version != 1 {
		return enrollmentRecord{}, ErrEnrollment
	}
	if len(fields) != len(required) {
		return enrollmentRecord{}, ErrEnrollment
	}
	for name := range fields {
		if !required[name] {
			return enrollmentRecord{}, ErrEnrollment
		}
	}
	if version == 2 {
		if _, err := enrollmentObject(fields["slots"], MaxLocalPeers, nil); err != nil {
			return enrollmentRecord{}, err
		}
	}
	peers, err := enrollmentObject(fields["peers"], MaxLocalPeers, nil)
	if err != nil {
		return enrollmentRecord{}, err
	}
	var record enrollmentRecord
	if err := json.Unmarshal(data, &record); err != nil || !validExecution(record.Execution) {
		return enrollmentRecord{}, ErrEnrollment
	}
	secret, err := base64.RawStdEncoding.DecodeString(record.Secret)
	if err != nil || len(secret) != 32 || base64.RawStdEncoding.EncodeToString(secret) != record.Secret {
		return enrollmentRecord{}, ErrEnrollment
	}
	for node := range peers {
		key, err := base64.RawStdEncoding.DecodeString(record.Peers[node])
		if !validPeer(node) || err != nil || len(key) != ed25519.PublicKeySize || base64.RawStdEncoding.EncodeToString(key) != record.Peers[node] {
			return enrollmentRecord{}, ErrEnrollment
		}
	}
	seen := make(map[int]bool, len(record.Slots))
	for node, slot := range record.Slots {
		if _, ok := record.Peers[node]; !ok || slot < 0 || slot >= MaxLocalPeers || seen[slot] {
			return enrollmentRecord{}, ErrEnrollment
		}
		seen[slot] = true
	}
	// Version-one transport entries have no process slot. Preserve them and
	// upgrade additively only when a later mutation actually writes the record.
	if record.Slots == nil {
		record.Slots = map[string]int{}
	}
	record.Version = 2
	return record, nil
}

func snapshot(record enrollmentRecord) Snapshot {
	secret, _ := base64.RawStdEncoding.DecodeString(record.Secret)
	s := Snapshot{execution: record.Execution, secret: secret, peers: make(map[string]ed25519.PublicKey, len(record.Peers))}
	for node, encoded := range record.Peers {
		key, _ := base64.RawStdEncoding.DecodeString(encoded)
		s.peers[node] = key
	}
	return s
}

// Initialize replaces per-execution bootstrap state. Only the owner holding the
// runtime application-state lock may call it, before publishing its descriptor.
// secret is the fresh 32-byte gossip key selected for that owner execution.
func (e *Enrollment) Initialize(ctx context.Context, execution string, secret []byte) error {
	if !validExecution(execution) || len(secret) != 32 {
		return ErrEnrollment
	}
	record := enrollmentRecord{Version: 2, Execution: execution, Secret: base64.RawStdEncoding.EncodeToString(secret), Peers: map[string]string{}, Slots: map[string]int{}}
	data, err := json.Marshal(record)
	if err != nil {
		return ErrEnrollment
	}
	return e.file.ReadModifyWrite(ctx, maxEnrollmentBytes, func(existing []byte) ([]byte, error) {
		if previous, err := decodeEnrollment(existing); err == nil && previous.Execution == execution {
			if previous.Secret != record.Secret {
				return nil, ErrBootstrapConflict
			}
			return nil, nil // Bootstrap retry must preserve already admitted keys.
		}
		return data, nil
	})
}

func (e *Enrollment) Read(ctx context.Context, execution string) (Snapshot, error) {
	data, err := e.file.Read(ctx, maxEnrollmentBytes)
	if err != nil {
		return Snapshot{}, err
	}
	record, err := decodeEnrollment(data)
	if err != nil {
		return Snapshot{}, err
	}
	if record.Execution != execution {
		return Snapshot{}, ErrOwnerChanged
	}
	return snapshot(record), nil
}

// Register is authorized by same-OS-user access to the private directory. The
// key is the client's public key; its private key never enters this store.
// Retrying the same identity/key is idempotent. Different keys conflict.
func (e *Enrollment) Register(ctx context.Context, execution, node string, key ed25519.PublicKey) (Snapshot, error) {
	if !validExecution(execution) || !validPeer(node) || len(key) != ed25519.PublicKeySize {
		return Snapshot{}, ErrEnrollment
	}
	encoded := base64.RawStdEncoding.EncodeToString(key)
	var result Snapshot
	err := e.file.ReadModifyWrite(ctx, maxEnrollmentBytes, func(data []byte) ([]byte, error) {
		record, err := decodeEnrollment(data)
		if err != nil {
			return nil, err
		}
		if record.Execution != execution {
			return nil, ErrOwnerChanged
		}
		if previous, ok := record.Peers[node]; ok {
			if previous != encoded {
				return nil, ErrPeerConflict
			}
			result = snapshot(record)
			return nil, nil
		}
		if len(record.Peers) >= MaxLocalPeers {
			return nil, ErrPeerCapacity
		}
		record.Peers[node] = encoded
		result = snapshot(record)
		return json.Marshal(record)
	})
	if err != nil {
		return Snapshot{}, err
	}
	return result, nil
}

// Remove retires only this execution's exact identity/key. Delayed cleanup may
// not remove a replacement owner's enrollment or a different client's key.
func (e *Enrollment) Remove(ctx context.Context, execution, node string, key ed25519.PublicKey) error {
	if !validExecution(execution) || !validPeer(node) || len(key) != ed25519.PublicKeySize {
		return ErrEnrollment
	}
	encoded := base64.RawStdEncoding.EncodeToString(key)
	return e.file.ReadModifyWrite(ctx, maxEnrollmentBytes, func(data []byte) ([]byte, error) {
		record, err := decodeEnrollment(data)
		if err != nil {
			return nil, err
		}
		if record.Execution != execution {
			return nil, ErrOwnerChanged
		}
		previous, ok := record.Peers[node]
		if !ok {
			return nil, nil
		}
		if previous != encoded {
			return nil, ErrPeerConflict
		}
		delete(record.Peers, node)
		delete(record.Slots, node)
		return json.Marshal(record)
	})
}

// Resolve is a fresh, bounded local-file lookup for a new handshake. It does no
// network I/O or background polling, and fails closed on malformed or replaced
// state. Callers supply the owner lifetime context. Established sessions need
// separate retirement; deleting enrollment does not close an existing socket.
func (e *Enrollment) Resolve(ctx context.Context, execution, node string) (ed25519.PublicKey, bool) {
	s, err := e.Read(ctx, execution)
	if err != nil {
		return nil, false
	}
	return s.PeerKey(node)
}
