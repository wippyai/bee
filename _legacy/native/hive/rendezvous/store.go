// SPDX-License-Identifier: MIT

package rendezvous

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/wippyai/bee/native/internal/privatefile"
)

const FileName = "mesh-owner.json"

type Store struct {
	file      *privatefile.File
	directory string
}

// New does not create state. Use a private discovery subdirectory of the
// selected runtime state directory, independently of all application databases.
func New(directory string) (*Store, error) {
	file, err := privatefile.New(directory, FileName, ".mesh-owner.lock")
	if err != nil {
		return nil, err
	}
	return &Store{file: file, directory: directory}, nil
}

func (s *Store) Read(ctx context.Context) (Descriptor, error) {
	data, err := s.file.Read(ctx, MaxBytes)
	if err != nil {
		return Descriptor{}, err
	}
	return Decode(data)
}

// Publish is for the native owner holding the runtime application-state lock.
// It replaces ephemeral discovery data atomically. It never changes workspace,
// registry or enrollment state. Publication uncertainty propagates to the caller.
// Leave the descriptor in place on shutdown: stale data proves no liveness and
// deleting it could race publication by a replacement owner.
func (s *Store) Publish(ctx context.Context, descriptor Descriptor) error {
	if err := descriptor.validate(); err != nil {
		return err
	}
	data, err := json.Marshal(descriptor)
	if err != nil {
		return err
	}
	return s.file.ReadModifyWrite(ctx, MaxBytes, func([]byte) ([]byte, error) { return data, nil })
}

// Clear retires only the exact stale descriptor, under the publication lock.
// The caller holds the runtime state lock and has verified that its PID is gone.
func (s *Store) Clear(ctx context.Context, expected Descriptor) error {
	return s.file.ReadModifyWrite(ctx, MaxBytes, func(data []byte) ([]byte, error) {
		if data == nil {
			return nil, nil
		}
		current, err := Decode(data)
		if err != nil {
			return nil, err
		}
		if current.Execution != expected.Execution || current.Launch != expected.Launch || current.OwnerPID != expected.OwnerPID {
			return nil, errors.New("Bee owner changed before stale record cleanup")
		}
		if err := os.Remove(filepath.Join(s.directory, FileName)); err != nil {
			return nil, err
		}
		directory, err := os.Open(s.directory)
		if err != nil {
			return nil, err
		}
		return nil, errors.Join(directory.Sync(), directory.Close())
	})
}
