// SPDX-License-Identifier: MIT

package hive

import (
	"errors"
	"os"
	"path/filepath"
)

func ensureStateIgnore(state string) error {
	path := filepath.Join(state, ".gitignore")
	if _, err := os.Lstat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	pending, err := os.CreateTemp(state, ".gitignore-")
	if err != nil {
		return err
	}
	defer os.Remove(pending.Name())
	if _, err := pending.WriteString("*"); err != nil {
		_ = pending.Close()
		return err
	}
	if err := pending.Sync(); err != nil {
		_ = pending.Close()
		return err
	}
	if err := pending.Close(); err != nil {
		return err
	}
	if err := os.Link(pending.Name(), path); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	return nil
}
