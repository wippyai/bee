// SPDX-License-Identifier: MIT

package config

import (
	"errors"
)

const (
	// ConfigFileName is the filename of the persistent machine configuration document.
	ConfigFileName = "config.json"

	// LockFileName is the filename of the exclusive companion lock file.
	LockFileName = ".config.lock"

	// CurrentVersion is the required schema version for machine configuration documents.
	CurrentVersion = 1

	// MaxDocumentBytes is the maximum allowed size of a configuration document (4 MiB).
	MaxDocumentBytes = 4 * 1024 * 1024

	// MaxWorkspaces is the maximum number of workspace entries allowed in a document.
	MaxWorkspaces = 4096

	// MaxIDBytes is the maximum allowed byte length of a WorkspaceID (160 bytes).
	MaxIDBytes = 160

	// MaxEnrollmentRefBytes is the maximum allowed byte length of an EnrollmentRef (160 bytes).
	MaxEnrollmentRefBytes = 160

	// MaxPathBytes is the maximum allowed byte length of a file path (4096 bytes).
	MaxPathBytes = 4096
)

var (
	// ErrConflict is returned when expectedRevision does not match the stored revision.
	ErrConflict = errors.New("config: revision conflict")

	// ErrMalformedDocument is returned when a document is malformed, corrupt, or violates schema bounds.
	ErrMalformedDocument = errors.New("config: malformed document")

	// ErrRevisionOverflow is returned when the document revision cannot be incremented without overflowing uint64.
	ErrRevisionOverflow = errors.New("config: revision overflow")
)

// Document represents the typed version 1 machine configuration.
// It tracks remembered workspace locations and an optional enrollment reference.
type Document struct {
	Version       int                 `json:"version"`
	Revision      uint64              `json:"revision"`
	EnrollmentRef string              `json:"enrollment_ref"`
	Workspaces    []WorkspaceLocation `json:"workspaces"`
}

// WorkspaceLocation records the mapping between an opaque workspace ID and its
// native filesystem paths. One WorkspaceID may have multiple ProjectDirs, but
// all its entries must agree on RuntimeStateDir. Each ProjectDir maps at most once.
// Several workspace IDs may share one runtime state directory. This is a
// location hint for registry/deployment storage, not a workspace database grant.
type WorkspaceLocation struct {
	WorkspaceID     string `json:"workspace_id"`
	ProjectDir      string `json:"project_dir"`
	RuntimeStateDir string `json:"runtime_state_dir"`
}

// Clone returns a deep copy of the document with an independent Workspaces slice.
func (d Document) Clone() Document {
	out := d
	if d.Workspaces != nil {
		out.Workspaces = make([]WorkspaceLocation, len(d.Workspaces))
		copy(out.Workspaces, d.Workspaces)
	} else {
		out.Workspaces = []WorkspaceLocation{}
	}
	return out
}
