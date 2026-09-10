// SPDX-License-Identifier: MIT

package config

import (
	"fmt"
	"path/filepath"
	"unicode"
	"unicode/utf8"
)

func validateDocument(doc Document, fromDisk bool) error {
	if len(doc.Workspaces) > MaxWorkspaces {
		return fmt.Errorf("%w: workspace entries limit exceeded", ErrMalformedDocument)
	}
	if doc.Version != CurrentVersion {
		return fmt.Errorf("%w: unsupported version", ErrMalformedDocument)
	}
	if fromDisk && doc.Revision == 0 {
		return fmt.Errorf("%w: revision must be positive on disk", ErrMalformedDocument)
	}
	if err := validateEnrollmentRef(doc.EnrollmentRef); err != nil {
		return err
	}
	for _, loc := range doc.Workspaces {
		if err := validateID(loc.WorkspaceID, "workspace_id"); err != nil {
			return err
		}
		if err := validatePath(loc.ProjectDir, "project_dir"); err != nil {
			return err
		}
		if err := validatePath(loc.RuntimeStateDir, "runtime_state_dir"); err != nil {
			return err
		}
	}
	return validateWorkspacesInvariants(doc.Workspaces)
}

func validateID(id, fieldName string) error {
	if len(id) == 0 {
		return fmt.Errorf("%w: %s cannot be empty", ErrMalformedDocument, fieldName)
	}
	if len(id) > MaxIDBytes {
		return fmt.Errorf("%w: %s exceeds maximum length", ErrMalformedDocument, fieldName)
	}
	if !utf8.ValidString(id) {
		return fmt.Errorf("%w: %s contains invalid UTF-8", ErrMalformedDocument, fieldName)
	}
	for _, r := range id {
		if unicode.IsControl(r) {
			return fmt.Errorf("%w: %s contains control character", ErrMalformedDocument, fieldName)
		}
	}
	return nil
}

func validateEnrollmentRef(ref string) error {
	if ref == "" {
		return nil
	}
	if len(ref) > MaxEnrollmentRefBytes {
		return fmt.Errorf("%w: enrollment_ref exceeds maximum length", ErrMalformedDocument)
	}
	if !utf8.ValidString(ref) {
		return fmt.Errorf("%w: enrollment_ref contains invalid UTF-8", ErrMalformedDocument)
	}
	for _, r := range ref {
		if unicode.IsControl(r) {
			return fmt.Errorf("%w: enrollment_ref contains control character", ErrMalformedDocument)
		}
	}
	return nil
}

func validatePath(path, fieldName string) error {
	if len(path) == 0 {
		return fmt.Errorf("%w: %s cannot be empty", ErrMalformedDocument, fieldName)
	}
	if len(path) > MaxPathBytes {
		return fmt.Errorf("%w: %s exceeds maximum length", ErrMalformedDocument, fieldName)
	}
	if !utf8.ValidString(path) {
		return fmt.Errorf("%w: %s contains invalid UTF-8", ErrMalformedDocument, fieldName)
	}
	for _, r := range path {
		if unicode.IsControl(r) {
			return fmt.Errorf("%w: %s contains control character", ErrMalformedDocument, fieldName)
		}
	}
	if !filepath.IsAbs(path) {
		return fmt.Errorf("%w: %s must be absolute path", ErrMalformedDocument, fieldName)
	}
	if filepath.Clean(path) != path {
		return fmt.Errorf("%w: %s must be canonical cleaned path", ErrMalformedDocument, fieldName)
	}
	return nil
}

func validateWorkspacesInvariants(workspaces []WorkspaceLocation) error {
	if len(workspaces) > MaxWorkspaces {
		return fmt.Errorf("%w: workspace entries limit exceeded", ErrMalformedDocument)
	}
	seenProjectDir := make(map[string]bool, len(workspaces))
	workspaceToState := make(map[string]string, len(workspaces))

	for _, loc := range workspaces {
		// Each ProjectDir maps once
		if seenProjectDir[loc.ProjectDir] {
			return fmt.Errorf("%w: duplicate project directory", ErrMalformedDocument)
		}
		seenProjectDir[loc.ProjectDir] = true

		// One WorkspaceID may have multiple ProjectDirs, but all its entries must agree on RuntimeStateDir
		if existingState, ok := workspaceToState[loc.WorkspaceID]; ok {
			if existingState != loc.RuntimeStateDir {
				return fmt.Errorf("%w: inconsistent state directory for workspace", ErrMalformedDocument)
			}
		} else {
			workspaceToState[loc.WorkspaceID] = loc.RuntimeStateDir
		}

	}
	return nil
}
