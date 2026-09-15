// SPDX-License-Identifier: MIT

package config

import (
	"context"
	"errors"
	"fmt"
	"math"
	"path/filepath"
	"strings"

	"github.com/wippyai/bee/native/internal/privatefile"
)

// Store provides protected, locked, versioned persistence for machine configuration.
// It relies on native OS-user filesystem authority via internal/privatefile.
type Store struct {
	file *privatefile.File
}

// New validates the directory path and returns a Store targeting the configuration file
// and companion lock file within directory. It does not create the directory or any files.
func New(directory string) (*Store, error) {
	if strings.TrimSpace(directory) == "" {
		return nil, errors.New("config: directory path is required")
	}
	cleanDir := filepath.Clean(directory)
	pf, err := privatefile.New(cleanDir, ConfigFileName, LockFileName)
	if err != nil {
		return nil, err
	}
	return &Store{
		file: pf,
	}, nil
}

// Read reads and strictly validates the persisted configuration document.
// If the document does not exist, os.ErrNotExist is returned without creating
// the directory or any files.
func (s *Store) Read(ctx context.Context) (Document, error) {
	if ctx == nil {
		return Document{}, errors.New("context is required")
	}
	if err := ctx.Err(); err != nil {
		return Document{}, err
	}

	data, err := s.file.Read(ctx, MaxDocumentBytes)
	if err != nil {
		return Document{}, err
	}

	doc, err := Decode(data)
	if err != nil {
		return Document{}, err
	}

	return doc.Clone(), nil
}

// Update executes transform inside an exclusive lock using privatefile.ReadModifyWrite.
//
// Behavior and Guarantees:
//   - If the configuration file is missing, transform begins with:
//     {Version: 1, Revision: 0, Hive: LocalHiveProfile(), Workspaces: []}.
//   - expectedRevision must match the existing document's revision; expectedRevision 0
//     is valid only when the document does not yet exist.
//   - Existing corrupt, empty, unknown, duplicate, case-aliased, null, missing, or unsupported
//     documents fail immediately without invoking transform or mutating the file.
//   - Stale expectedRevision values fail with ErrConflict without invoking transform or mutating the file.
//   - Store sets Version = 1 and Revision = current + 1. Transform must not alter metadata.
//   - Transform failure or schema validation failure aborts the update and preserves existing bytes.
//   - Deep copies of input and output slices ensure that retained references cannot mutate committed state.
//   - A nil transform function is rejected immediately without touching the filesystem.
//   - Returns the committed document only on success (zero Document on failure or uncertain publication).
func (s *Store) Update(ctx context.Context, expectedRevision uint64, transform func(Document) (Document, error)) (Document, error) {
	if ctx == nil {
		return Document{}, errors.New("context is required")
	}
	if err := ctx.Err(); err != nil {
		return Document{}, err
	}
	if transform == nil {
		return Document{}, errors.New("config: transform function is required")
	}

	var committed Document

	err := s.file.ReadModifyWrite(ctx, MaxDocumentBytes, func(existing []byte) ([]byte, error) {
		var currentDoc Document
		if existing == nil {
			if expectedRevision != 0 {
				return nil, ErrConflict
			}
			currentDoc = Document{
				Version:    CurrentVersion,
				Revision:   0,
				Hive:       LocalHiveProfile(),
				Workspaces: []WorkspaceLocation{},
			}
		} else {
			if len(existing) == 0 {
				return nil, fmt.Errorf("%w: empty document", ErrMalformedDocument)
			}
			loadedDoc, err := decodeDocument(existing, true)
			if err != nil {
				return nil, err
			}
			if expectedRevision != loadedDoc.Revision {
				return nil, ErrConflict
			}
			currentDoc = loadedDoc
		}

		if currentDoc.Revision == math.MaxUint64 {
			return nil, ErrRevisionOverflow
		}

		inputDoc := currentDoc.Clone()

		transformedDoc, err := transform(inputDoc)
		if err != nil {
			return nil, err
		}

		if transformedDoc.Version != currentDoc.Version || transformedDoc.Revision != currentDoc.Revision {
			return nil, fmt.Errorf("%w: transform attempted to modify metadata", ErrMalformedDocument)
		}

		resultDoc := transformedDoc.Clone()
		resultDoc.Version = CurrentVersion
		resultDoc.Revision = currentDoc.Revision + 1

		if resultDoc.Workspaces == nil {
			resultDoc.Workspaces = []WorkspaceLocation{}
		}

		if err := validateDocument(resultDoc, true); err != nil {
			return nil, err
		}

		payload, err := marshalDocument(resultDoc)
		if err != nil {
			return nil, err
		}

		committed = resultDoc.Clone()

		return payload, nil
	})

	if err != nil {
		return Document{}, err
	}
	return committed.Clone(), nil
}
