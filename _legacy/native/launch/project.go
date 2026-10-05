// SPDX-License-Identifier: MIT

// Package launch contains Bee's small native host boundary. The runtime owns
// state opening, locking, deployment and application lifecycle; this package
// only chooses the default state directory before those operations begin.
package launch

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const (
	legacyProjectFile     = "project-state.json"
	legacyProjectMaxBytes = 16 * 1024
)

// legacyProjectSelection is the receipt written by older Bee versions. It is
// read only so a new executable can reopen an existing legacy root without
// making a migration decision or changing durable state during planning.
type legacyProjectSelection struct {
	Version    int    `json:"version"`
	Mode       string `json:"mode"`
	ProjectDir string `json:"project_dir"`
	StateDir   string `json:"state_dir"`
}

// ProjectStateDir returns the state directory for one canonical project. It
// does not inspect or create the root; callers can use it during planning.
func ProjectStateDir(root, directory string) (string, error) {
	root, directory, err := canonicalStateInputs(root, directory)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(directory))
	return filepath.Join(root, "projects", hex.EncodeToString(digest[:])), nil
}

// DefaultProjectStateDir selects the state for a non-explicit launch. The
// hashed directory is the normal choice. A valid receipt from an older Bee
// version binds its matching project to the old root for compatibility; a
// valid receipt for another project and an absent receipt both select the
// hashed directory.
//
// Planning is deliberately read-only. In particular, this function does not
// create a receipt, inspect databases, acquire a lock, or open runtime state.
func DefaultProjectStateDir(root, directory string) (string, error) {
	root, directory, err := canonicalStateInputs(root, directory)
	if err != nil {
		return "", err
	}
	projectState, err := ProjectStateDir(root, directory)
	if err != nil {
		return "", err
	}

	receipt, err := readProjectReceipt(filepath.Join(root, legacyProjectFile))
	if errors.Is(err, os.ErrNotExist) {
		return projectState, nil
	}
	if err != nil {
		return "", err
	}
	if receipt.ProjectDir == directory && receipt.StateDir == root {
		return root, nil
	}
	return projectState, nil
}

func canonicalStateInputs(root, directory string) (string, string, error) {
	if !filepath.IsAbs(root) || !filepath.IsAbs(directory) {
		return "", "", errors.New("project state requires absolute root and directory")
	}
	root = filepath.Clean(root)
	directory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return "", "", fmt.Errorf("canonicalize project directory: %w", err)
	}
	if !filepath.IsAbs(directory) {
		return "", "", errors.New("canonical project directory is not absolute")
	}
	return root, filepath.Clean(directory), nil
}

func readProjectReceipt(path string) (legacyProjectSelection, error) {
	file, err := os.Open(path)
	if err != nil {
		return legacyProjectSelection{}, err
	}
	defer file.Close()

	data, err := io.ReadAll(io.LimitReader(file, legacyProjectMaxBytes+1))
	if err != nil {
		return legacyProjectSelection{}, fmt.Errorf("read project state receipt: %w", err)
	}
	if len(data) > legacyProjectMaxBytes {
		return legacyProjectSelection{}, errors.New("invalid project state receipt: file is too large")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var receipt legacyProjectSelection
	if err := decoder.Decode(&receipt); err != nil {
		return legacyProjectSelection{}, fmt.Errorf("invalid project state receipt: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return legacyProjectSelection{}, errors.New("invalid project state receipt: trailing value")
		}
		return legacyProjectSelection{}, fmt.Errorf("invalid project state receipt: %w", err)
	}
	if receipt.Version != 1 || receipt.Mode != "legacy-root" ||
		!filepath.IsAbs(receipt.ProjectDir) || filepath.Clean(receipt.ProjectDir) != receipt.ProjectDir ||
		!filepath.IsAbs(receipt.StateDir) || filepath.Clean(receipt.StateDir) != receipt.StateDir {
		return legacyProjectSelection{}, errors.New("invalid project state receipt: unsupported selection")
	}
	return receipt, nil
}
