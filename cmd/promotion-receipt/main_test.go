// SPDX-License-Identifier: MIT

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestInspectAndAtomicReceiptWrite(t *testing.T) {
	root := t.TempDir()
	input := filepath.Join(root, "artifact")
	content := []byte("immutable artifact\n")
	if err := os.WriteFile(input, content, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := inspect(input)
	if err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256(content)
	if got.SHA256 != hex.EncodeToString(want[:]) || got.Bytes != int64(len(content)) {
		t.Fatalf("unexpected artifact identity: %#v", got)
	}

	output := filepath.Join(root, "receipts", "promotion.json")
	if err := writeAtomic(output, []byte("first\n")); err != nil {
		t.Fatal(err)
	}
	if err := writeAtomic(output, []byte("second\n")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(output)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "second\n" || info.Mode().Perm() != 0600 {
		t.Fatalf("unexpected atomic receipt: content=%q mode=%#o", string(data), info.Mode().Perm())
	}
}

func TestVerifyProvenanceAndPackAudit(t *testing.T) {
	root := t.TempDir()
	generation := filepath.Join(root, "native-bundles", "generation")
	packDir := filepath.Join(generation, "packs", "bee")
	if err := os.MkdirAll(packDir, 0700); err != nil {
		t.Fatal(err)
	}
	packPath := filepath.Join(packDir, "bee.wapp")
	if err := os.WriteFile(packPath, []byte("pack\n"), 0600); err != nil {
		t.Fatal(err)
	}
	pack, err := inspect(packPath)
	if err != nil {
		t.Fatal(err)
	}
	manifest := testManifest()
	manifest["application"].(map[string]any)["packs"] = []any{map[string]any{
		"module": "bee/bee", "version": "0.1.0", "path": "native-bundles/generation/packs/bee/bee.wapp", "sha256": pack.SHA256,
	}}
	manifestData, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, "bundle.json")
	if err := os.WriteFile(manifestPath, manifestData, 0600); err != nil {
		t.Fatal(err)
	}
	build := testManifest()
	build["application"].(map[string]any)["packs"] = []any{map[string]any{
		"module": "bee/bee", "version": "0.1.0", "path": "dist/bee-native.wapp", "sha256": "source-pack",
	}}
	buildData, err := json.Marshal(build)
	if err != nil {
		t.Fatal(err)
	}
	buildPath := filepath.Join(root, "build.json")
	if err := os.WriteFile(buildPath, buildData, 0600); err != nil {
		t.Fatal(err)
	}
	ownership := `{"assets":{},"entries":{"bee:app":{"kind":"process.lua","owner":"bee/bee"}}}`
	if err := os.WriteFile(filepath.Join(generation, "ownership.json"), []byte(ownership), 0600); err != nil {
		t.Fatal(err)
	}
	audit, err := auditPackManifestWithLoader(manifestPath, func(module, path string) (map[string]string, error) {
		if module != "bee/bee" || path != packPath {
			t.Fatalf("unexpected pack load: %s %s", module, path)
		}
		return map[string]string{"bee:app": "process.lua"}, nil
	})
	if err != nil || audit.Entries != 1 || audit.Packs != 1 || audit.EmbeddedAssets != 0 {
		t.Fatalf("unexpected pack audit: %#v, %v", audit, err)
	}

	artifacts := make([]artifact, len(artifactSuffixes))
	for index := range artifacts {
		artifacts[index].SHA256 = string(rune('a' + index))
	}
	modified := false
	provenance := map[string]any{"schema": 1, "mode": "application", "manifest": manifest,
		"builder": map[string]any{"revision": "builder-commit", "modified": modified, "go": "go1.27.0"}, "artifacts": map[string]string{
			"binary": artifacts[0].SHA256, "licenses": artifacts[1].SHA256,
			"go.mod": artifacts[2].SHA256, "go.sum": artifacts[3].SHA256,
			"runtime-patches": artifacts[5].SHA256,
		}}
	provenanceData, err := json.Marshal(provenance)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyProvenance(provenanceData, artifacts, buildPath, manifestPath); err != nil {
		t.Fatal(err)
	}
	provenanceWithoutBuilder := map[string]any{"schema": 1, "mode": "application", "manifest": manifest, "artifacts": provenance["artifacts"]}
	missingBuilderData, err := json.Marshal(provenanceWithoutBuilder)
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyProvenance(missingBuilderData, artifacts, buildPath, manifestPath); err == nil {
		t.Fatal("provenance without builder identity passed")
	}
	if _, err := auditPackManifestWithLoader(manifestPath, func(string, string) (map[string]string, error) {
		return map[string]string{"bee:other": "process.lua"}, nil
	}); err == nil {
		t.Fatal("pack differing from ownership inventory passed")
	}
	embedOwnership := `{"assets":{},"entries":{"bee:asset":{"kind":"fs.embed","owner":"bee/bee"}}}`
	if err := os.WriteFile(filepath.Join(generation, "ownership.json"), []byte(embedOwnership), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := auditPackManifestWithLoader(manifestPath, func(string, string) (map[string]string, error) {
		return map[string]string{"bee:asset": "fs.embed"}, nil
	}); err == nil {
		t.Fatal("embedded filesystem entry passed with an empty asset inventory")
	}
	artifacts[5].SHA256 = "changed"
	if err := verifyProvenance(provenanceData, artifacts, buildPath, manifestPath); err == nil {
		t.Fatal("changed runtime patch sidecar matched provenance")
	}
	artifacts[5].SHA256 = string(rune('a' + 5))
	build["runtime"].(map[string]any)["commit"] = "other-runtime"
	changedBuild, err := json.Marshal(build)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(buildPath, changedBuild, 0600); err != nil {
		t.Fatal(err)
	}
	if err := verifyProvenance(provenanceData, artifacts, buildPath, manifestPath); err == nil {
		t.Fatal("unrelated build manifest matched candidate provenance")
	}

	badOwnership := `{"assets":{},"entries":{"bee.fixture:sample":{"kind":"process.lua","owner":"bee/bee"}}}`
	if err := os.WriteFile(filepath.Join(generation, "ownership.json"), []byte(badOwnership), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := auditPackManifestWithLoader(manifestPath, func(string, string) (map[string]string, error) {
		return map[string]string{"bee.fixture:sample": "process.lua"}, nil
	}); err == nil {
		t.Fatal("fixture registration passed production pack audit")
	}
}

func testManifest() map[string]any {
	return map[string]any{
		"schema": 1,
		"name":   "bee",
		"runtime": map[string]any{
			"repository": "https://example.invalid/runtime.git",
			"commit":     "runtime-commit",
			"go":         "1.27.0",
			"tags":       []any{"meshclient"},
			"patches":    []any{map[string]any{"path": "patch", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
		},
		"application": map[string]any{
			"module": "bee/bee", "command": "bee",
			"data": map[string]any{"BEE_THREADS_DB": "threads.db"},
		},
		"native": []any{map[string]any{
			"module": "github.com/wippyai/bee/native", "version": "v1.0.0",
			"package": "github.com/wippyai/bee/native/desktop", "factory": "Component",
			"private": true, "host": true,
		}},
	}
}

func TestCandidateBundleWhenRequested(t *testing.T) {
	binary := os.Getenv("BEE_PROMOTION_TEST_BINARY")
	bundle := os.Getenv("BEE_PROMOTION_TEST_BUNDLE")
	runtime := os.Getenv("BEE_PROMOTION_TEST_RUNTIME")
	build := os.Getenv("BEE_PROMOTION_TEST_BUILD_MANIFEST")
	if binary == "" || bundle == "" || runtime == "" || build == "" {
		t.Skip("set BEE_PROMOTION_TEST_BINARY, BEE_PROMOTION_TEST_RUNTIME, BEE_PROMOTION_TEST_BUILD_MANIFEST and BEE_PROMOTION_TEST_BUNDLE")
	}
	artifacts := make([]artifact, 0, len(artifactSuffixes))
	for _, suffix := range artifactSuffixes {
		item, err := inspect(binary + suffix)
		if err != nil {
			t.Fatal(err)
		}
		artifacts = append(artifacts, item)
	}
	provenance, err := os.ReadFile(binary + ".provenance.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := verifyProvenance(provenance, artifacts, build, bundle); err != nil {
		t.Fatal(err)
	}
	audit, err := auditPackManifest(runtime, bundle)
	if err != nil {
		t.Fatal(err)
	}
	if audit.Entries == 0 || audit.EmbeddedAssets != 0 {
		t.Fatalf("unexpected pack audit: %#v", audit)
	}
}
