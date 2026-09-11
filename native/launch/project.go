//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"path/filepath"

	application "github.com/wippyai/runtime/api/application"
)

// SelectProject scopes implicit application state to the canonical launch folder.
// It performs no writes. Explicit state remains authoritative, including the
// selected state passed to a detached owner child.
func SelectProject(request application.LaunchRequest) (application.LaunchRequest, error) {
	if request.Operation != application.RunApplication || request.ExplicitState {
		return request, nil
	}
	if !filepath.IsAbs(request.Directory) || !filepath.IsAbs(request.StateDir) {
		return request, errors.New("project launch requires absolute project and state directories")
	}
	directory, err := filepath.EvalSymlinks(request.Directory)
	if err != nil {
		return request, err
	}
	directory = filepath.Clean(directory)
	digest := sha256.Sum256([]byte(directory))
	request.Directory = directory
	request.StateDir = filepath.Join(request.StateDir, "projects", hex.EncodeToString(digest[:]))
	return request, nil
}
