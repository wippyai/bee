// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/uuid"
	"github.com/wippyai/bee/native/internal/privatefile"
	"github.com/wippyai/runtime/api/boot"
)

const (
	stateNodeIdentityName = "node.identity.json"
	stateNodeIdentityLock = "node.identity.lock"
	stateNodeFileMaxBytes = 16 * 1024
)

type storedNodeIdentity struct {
	Version      int    `json:"version"`
	NodeID       string `json:"node_id"`
	LegacyNodeID string `json:"legacy_node_id"`
}

// prepareStateNodeIdentity persists this state's node identity before the
// runtime opens its stores. The identity lock remains held for the runtime's
// lifetime so two launch routes cannot open the same state concurrently.
func prepareStateNodeIdentity(ctx context.Context, state, projectDir string) (boot.Config, func() error, error) {
	identity, release, err := ensureStateNodeIdentity(ctx, state, projectDir)
	if err != nil {
		return nil, nil, err
	}
	config := boot.NewConfig(
		boot.WithSection("relay", map[string]any{"node_name": identity.NodeID}),
		boot.WithSection("cluster", map[string]any{"name": identity.NodeID}),
	)
	return config, release, nil
}

func ensureStateNodeIdentity(ctx context.Context, state, projectDir string) (storedNodeIdentity, func() error, error) {
	if ctx == nil || !filepath.IsAbs(state) || !filepath.IsAbs(projectDir) {
		return storedNodeIdentity{}, nil, errors.New("state node identity requires absolute state and project directories")
	}
	state = filepath.Clean(state)
	projectDir = filepath.Clean(projectDir)
	directory := ownerDirectory(state)
	if err := privatefile.EnsurePrivateDir(directory); err != nil {
		return storedNodeIdentity{}, nil, err
	}
	unlock, err := privatefile.TryLock(ctx, directory, stateNodeIdentityLock)
	if err != nil {
		return storedNodeIdentity{}, nil, fmt.Errorf("lock state node identity: %w", err)
	}
	identity, err := readStoredNodeIdentity(state)
	if errors.Is(err, os.ErrNotExist) {
		identity = storedNodeIdentity{Version: 1, NodeID: runtimeNodeID(projectDir),
			LegacyNodeID: ownerNodeNameFromState(state)}
		if identity.LegacyNodeID == identity.NodeID {
			identity.LegacyNodeID = ""
		}
		if err := writeNodeIdentity(state, identity); err != nil {
			return storedNodeIdentity{}, nil, errors.Join(fmt.Errorf("persist state node identity: %w", err), unlock())
		}
	} else if err != nil {
		return storedNodeIdentity{}, nil, errors.Join(err, unlock())
	}
	return identity, unlock, nil
}

func readStoredNodeIdentity(state string) (storedNodeIdentity, error) {
	path := filepath.Join(ownerDirectory(state), stateNodeIdentityName)
	data, err := readOwnerFile(path, stateNodeFileMaxBytes)
	if err != nil {
		return storedNodeIdentity{}, err
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	var identity storedNodeIdentity
	if err := decoder.Decode(&identity); err != nil {
		return storedNodeIdentity{}, fmt.Errorf("decode state node identity: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return storedNodeIdentity{}, errors.New("state node identity contains trailing JSON")
		}
		return storedNodeIdentity{}, fmt.Errorf("decode state node identity: %w", err)
	}
	if identity.Version != 1 || !validTrustedName(identity.NodeID) ||
		(identity.LegacyNodeID != "" && !validTrustedName(identity.LegacyNodeID)) {
		return storedNodeIdentity{}, errors.New("state node identity is invalid")
	}
	return identity, nil
}

func writeNodeIdentity(state string, identity storedNodeIdentity) error {
	data, err := json.Marshal(identity)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return writeOwnerFile(filepath.Join(ownerDirectory(state), stateNodeIdentityName), data)
}

// runtimeNodeID matches Wippy's default identity. Keeping it as the initial
// state identity preserves local overlay and resource records created by
// ordinary Wippy launches; the former native path identity is the migration
// alias.
func runtimeNodeID(projectDir string) string {
	for _, name := range []string{"WIPPY_NODE_ID", "WIPPY_RELAY_NODE_NAME"} {
		if node := strings.TrimSpace(os.Getenv(name)); node != "" {
			return node
		}
	}
	host := ""
	if raw, err := os.ReadFile("/etc/machine-id"); err == nil {
		host = strings.TrimSpace(string(raw))
	}
	if host == "" {
		if value, err := os.Hostname(); err == nil {
			host = strings.TrimSpace(value)
		}
	}
	if host == "" && projectDir == "" {
		return ""
	}
	return uuid.NewSHA1(uuid.NameSpaceOID, []byte("wippy-node:"+host+"\x00"+projectDir)).String()
}

func ownerNodeNameFromState(state string) string {
	digest := sha256.Sum256([]byte(filepath.Clean(state)))
	return "bee-owner-" + hex.EncodeToString(digest[:])[:16]
}
