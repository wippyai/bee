// SPDX-License-Identifier: MIT

package launch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/hive/invite"
	"github.com/wippyai/bee/native/hive/meshtls"
	"github.com/wippyai/bee/native/internal/privatefile"
)

const (
	// ownerLockName is held by the owner for its whole lifetime and by a hive
	// join while it rewrites the mesh the next owner boots with, so the two
	// never overlap.
	ownerLockName = "owner.lock"
	// joinedRecordName marks a node that joined another node's hive: it names
	// the hive node, the gossip seed and the hive's authority pool. The mesh
	// secret and the certified leaf the hive node issued sit beside it.
	joinedRecordName     = "joined.json"
	joinedSecretName     = "joined.secret"
	joinedCredentialName = "joined.pem"
	maxJoinedRecordBytes = meshtls.MaxBytes + 1024
)

// meshAddress is where the owner's mesh and join listener bind and what they
// advertise. The owner serves loopback only.
var meshAddress = netip.MustParseAddr("127.0.0.1")

// joinedRecord is the persisted outcome of a hive join.
type joinedRecord struct {
	Node        string `json:"node"`
	Gossip      string `json:"gossip"`
	Authorities string `json:"authorities"`
}

// lockOwner takes the owner lock of state, refusing while another owner runs
// or a hive join rewrites the mesh.
func lockOwner(ctx context.Context, state string) (func() error, error) {
	directory := ownerDirectory(state)
	if err := privatefile.EnsurePrivateDir(directory); err != nil {
		return nil, err
	}
	unlock, err := privatefile.TryLock(ctx, directory, ownerLockName)
	if errors.Is(err, privatefile.ErrLockBusy) {
		return nil, errOwnerRunning
	}
	return unlock, err
}

var errOwnerRunning = errors.New("this Bee is running")

// readJoined returns the joined record of state, if the node joined a hive.
func readJoined(state string) (joinedRecord, bool, error) {
	data, err := os.ReadFile(filepath.Join(ownerDirectory(state), joinedRecordName))
	if errors.Is(err, os.ErrNotExist) {
		return joinedRecord{}, false, nil
	}
	if err != nil {
		return joinedRecord{}, false, err
	}
	var record joinedRecord
	if len(data) > maxJoinedRecordBytes || strictJSON(data, &record) != nil || !invite.ValidNode(record.Node) {
		return joinedRecord{}, false, errors.New("joined hive record is invalid")
	}
	if _, err := netip.ParseAddrPort(record.Gossip); err != nil {
		return joinedRecord{}, false, errors.New("joined hive record is invalid")
	}
	if _, err := meshtls.Authorities([]byte(record.Authorities)); err != nil {
		return joinedRecord{}, false, errors.New("joined hive record is invalid")
	}
	return record, true, nil
}

func strictJSON(data []byte, into any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(into)
}

// membershipSecretPath is the secret the owner's mesh uses: the hive's secret
// once the node joined one, else its own.
func membershipSecretPath(state string) (string, error) {
	_, joined, err := readJoined(state)
	if err != nil {
		return "", err
	}
	if joined {
		return filepath.Join(ownerDirectory(state), joinedSecretName), nil
	}
	return filepath.Join(ownerDirectory(state), membershipSecretName), nil
}

// ensureAuthority returns the node's own mesh authority, creating it once.
func ensureAuthority(directory string, now time.Time) (meshtls.Authority, error) {
	path := filepath.Join(directory, meshtls.AuthorityFile)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if data, err = meshtls.NewAuthority(now); err != nil {
			return meshtls.Authority{}, err
		}
		if err := writeOwnerFile(path, data); err != nil {
			return meshtls.Authority{}, err
		}
	} else if err != nil {
		return meshtls.Authority{}, err
	}
	return meshtls.DecodeAuthority(data, now)
}

// prepareMesh writes the credential and authority pool the owner's mesh uses
// in this boot and returns its secret file and gossip seed. A joined node uses
// the leaf its hive node certified and trusts that hive's pool beside its own
// authority; any other node certifies a fresh leaf with its own authority.
func prepareMesh(state string, now time.Time) (string, string, error) {
	directory := ownerDirectory(state)
	authority, err := ensureAuthority(directory, now)
	if err != nil {
		return "", "", err
	}
	record, joined, err := readJoined(state)
	if err != nil {
		return "", "", err
	}
	var credential, pool []byte
	secret, seed := filepath.Join(directory, membershipSecretName), ""
	if joined {
		if credential, err = os.ReadFile(filepath.Join(directory, joinedCredentialName)); err != nil {
			return "", "", fmt.Errorf("joined hive credential: %w", err)
		}
		if pool, err = meshtls.Pool(authority.Certificate(), []byte(record.Authorities)); err != nil {
			return "", "", err
		}
		secret, seed = filepath.Join(directory, joinedSecretName), record.Gossip
	} else {
		public, private, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return "", "", err
		}
		leaf, err := authority.Issue(public, []netip.Addr{meshAddress}, now)
		if err != nil {
			return "", "", err
		}
		if credential, err = meshtls.Credential(leaf, private); err != nil {
			return "", "", err
		}
		if pool, err = meshtls.Pool(authority.Certificate()); err != nil {
			return "", "", err
		}
	}
	if err := writeOwnerFile(filepath.Join(directory, meshtls.CredentialFile), credential); err != nil {
		return "", "", err
	}
	if err := writeOwnerFile(filepath.Join(directory, meshtls.AuthoritiesFile), pool); err != nil {
		return "", "", err
	}
	return secret, seed, nil
}
