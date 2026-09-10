// SPDX-License-Identifier: MIT
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestNativePatchInputsAreFrozenAndVerified(t *testing.T) {
	root := t.TempDir()
	manifest := filepath.Join(root, "build.json")
	patch := filepath.Join(root, "runtime.patch")
	const original = "verified bytes"
	if err := os.WriteFile(patch, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(map[string]any{"runtime": map[string]any{
		"repository": "https://example.invalid/runtime.git", "commit": "0123456789012345678901234567890123456789", "go": "1.27.0",
		"patches": []map[string]string{{"path": "runtime.patch", "sha256": fmt.Sprintf("%x", sha256.Sum256([]byte(original)))}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifest, data, 0600); err != nil {
		t.Fatal(err)
	}
	_, patches, err := nativeTestInputs(manifest, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(patch, []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	frozen, err := os.ReadFile(patches[0])
	if err != nil || string(frozen) != original {
		t.Fatalf("input changed after verification: %q %v", frozen, err)
	}
	if _, _, err := nativeTestInputs(manifest, t.TempDir()); err == nil {
		t.Fatal("accepted changed patch")
	}
}
