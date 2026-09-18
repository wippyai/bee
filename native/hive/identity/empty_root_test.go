// SPDX-License-Identifier: MIT
package identity

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestRootEmptyIdentityIsNotRecreated(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "identity")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, IdentityFileName)
	if err := os.WriteFile(path, []byte{}, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenOrCreate(context.Background(), dir); err == nil {
		t.Fatal("empty existing identity accepted")
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) != 0 {
		t.Fatalf("empty identity replaced: %v", err)
	}
}
