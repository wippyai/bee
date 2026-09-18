// SPDX-License-Identifier: MIT
//go:build !windows

package identity

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestRootInsecureExistingDirectoryIsNotRepaired(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "existing")
	if err := os.Mkdir(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	_, err := OpenOrCreate(context.Background(), dir)
	if err == nil {
		t.Error("insecure existing directory was accepted")
	}
	st, statErr := os.Stat(dir)
	if statErr != nil {
		t.Fatal(statErr)
	}
	if st.Mode().Perm() != 0755 {
		t.Error("validation changed existing directory permissions")
	}
	if _, statErr = os.Stat(filepath.Join(dir, IdentityFileName)); !os.IsNotExist(statErr) {
		t.Error("refusal created an identity")
	}
}
