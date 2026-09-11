//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"path/filepath"

	app "github.com/wippyai/runtime/cmd/app"
)

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
	if !filepath.IsAbs(root) || !filepath.IsAbs(directory) {
		return "", errors.New("project state requires absolute root and directory")
	}
	directory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(filepath.Clean(directory)))
	return filepath.Join(root, "projects", hex.EncodeToString(digest[:])), nil
}
