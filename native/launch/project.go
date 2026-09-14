//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
	app "github.com/wippyai/runtime/cmd/app"
)

const (
	legacyProjectFile     = "project-state.json"
	legacyProjectLock     = ".project-state.lock"
	legacyProjectMaxBytes = 16 * 1024
	applicationLock       = ".application.lock"
)

type legacyProjectSelection struct {
	Version    int    `json:"version"`
	Mode       string `json:"mode"`
	ProjectDir string `json:"project_dir"`
	StateDir   string `json:"state_dir"`
}

// CanonicalProject preserves the native node identity across symlink aliases.
// It deliberately does not alter StateDir: cmd/app resolves that before Launch.
func CanonicalProject(request app.LaunchRequest) (app.LaunchRequest, error) {
	if !filepath.IsAbs(request.Directory) || !filepath.IsAbs(request.StateDir) {
		return request, errors.New("project launch requires absolute project and state directories")
	}
	directory, err := filepath.EvalSymlinks(request.Directory)
	if err != nil {
		return request, err
	}
	directory = filepath.Clean(directory)
	request.Directory = directory
	return request, nil
}

// ProjectStateDir is for the executable entry, before cmd/app.Run resolves its
// default. It preserves the caller-selected root while assigning one runtime
// state directory per canonical project. Explicit --state-dir remains outside
// this helper and is passed to cmd/app unchanged.
func ProjectStateDir(root, directory string) (string, error) {
	root, directory, err := canonicalStateInputs(root, directory)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(filepath.Clean(directory)))
	return filepath.Join(root, "projects", hex.EncodeToString(digest[:])), nil
}

// DefaultProjectStateDir selects project-scoped state while preserving the
// state created by Bee versions that used root for every launch folder. The
// first canonical project opened against a legacy root is bound to that root by
// one protected receipt; later projects use their digest-qualified directory.
// No databases are copied or removed, so the previous executable can still use
// the legacy root for rollback.
func DefaultProjectStateDir(root, directory string) (string, error) {
	root, directory, err := canonicalStateInputs(root, directory)
	if err != nil {
		return "", err
	}
	projectState, err := ProjectStateDir(root, directory)
	if err != nil {
		return "", err
	}

	receipt, err := privatefile.New(root, legacyProjectFile, legacyProjectLock)
	if err != nil {
		return "", fmt.Errorf("project state receipt: %w", err)
	}
	if _, err := os.Lstat(root); errors.Is(err, os.ErrNotExist) {
		return projectState, nil
	} else if err != nil {
		return "", fmt.Errorf("inspect Bee state root: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	selected := projectState
	var releaseApplicationLock func() error
	defer func() {
		if releaseApplicationLock != nil {
			_ = releaseApplicationLock()
		}
	}()
	err = receipt.ReadModifyWrite(ctx, legacyProjectMaxBytes, func(existing []byte) ([]byte, error) {
		if existing != nil {
			resolved, err := resolveLegacyProject(existing, root, directory, projectState)
			if err != nil {
				return nil, err
			}
			selected = resolved
			return nil, nil
		}
		legacy, err := hasLegacyState(root)
		if err != nil {
			return nil, err
		}
		if !legacy {
			return nil, nil
		}
		releaseApplicationLock, err = privatefile.TryLock(ctx, root, applicationLock)
		if errors.Is(err, privatefile.ErrLockBusy) {
			return nil, errors.New("legacy Bee is running; stop it before the project-state upgrade")
		}
		if err != nil {
			return nil, fmt.Errorf("lock legacy Bee state: %w", err)
		}
		selection := legacyProjectSelection{
			Version:    1,
			Mode:       "legacy-root",
			ProjectDir: directory,
			StateDir:   root,
		}
		encoded, err := json.Marshal(selection)
		if err != nil {
			return nil, err
		}
		encoded = append(encoded, '\n')
		selected = root
		return encoded, nil
	})
	if err != nil {
		return "", fmt.Errorf("commit project state receipt: %w", err)
	}
	return selected, nil
}

func canonicalStateInputs(root, directory string) (string, string, error) {
	if !filepath.IsAbs(root) || !filepath.IsAbs(directory) {
		return "", "", errors.New("project state requires absolute root and directory")
	}
	root = filepath.Clean(root)
	directory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return "", "", err
	}
	return root, filepath.Clean(directory), nil
}

func resolveLegacyProject(data []byte, root, directory, projectState string) (string, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var selection legacyProjectSelection
	if err := decoder.Decode(&selection); err != nil {
		return "", fmt.Errorf("invalid project state receipt: %w", err)
	}
	if err := requireJSONEnd(decoder); err != nil {
		return "", err
	}
	if selection.Version != 1 || selection.Mode != "legacy-root" ||
		!filepath.IsAbs(selection.ProjectDir) || filepath.Clean(selection.ProjectDir) != selection.ProjectDir ||
		selection.StateDir != root {
		return "", errors.New("invalid project state receipt")
	}
	if selection.ProjectDir == directory {
		return root, nil
	}
	return projectState, nil
}

func requireJSONEnd(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("invalid project state receipt: trailing value")
		}
		return fmt.Errorf("invalid project state receipt: %w", err)
	}
	return nil
}

func hasLegacyState(root string) (bool, error) {
	for _, name := range []string{
		".application.lock",
		"approvals.db",
		"artifact-cache",
		"credentials.db",
		"deployment",
		"gateway.db",
		"governance.db",
		"local-mesh",
		"node.db",
		"placement",
		"placement.db",
		"registry.db",
		"resources.db",
		"threads.db",
		"workspace.db",
		"workspace.db.client",
	} {
		_, err := os.Lstat(filepath.Join(root, name))
		if err == nil {
			return true, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return false, fmt.Errorf("inspect legacy state %q: %w", name, err)
		}
	}
	return false, nil
}
