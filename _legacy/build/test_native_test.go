// SPDX-License-Identifier: MIT
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNativeRuntimeRequiresExactUpstreamPinWithoutReplacement(t *testing.T) {
	manifest, err := nativeTestInputs(filepath.Join("..", "wippy.build.json"))
	if err != nil {
		t.Fatal(err)
	}
	version := "v0.1.14-0.20261002182300-" + manifest.Runtime.Commit[:12]
	if err := verifyRuntimeModule(manifest, runtimeModule{Version: version}); err != nil {
		t.Fatal(err)
	}
	for _, dependency := range []runtimeModule{{Version: "v0.1.14"}, {Version: version, Replace: &runtimeModule{Version: version}}} {
		if verifyRuntimeModule(manifest, dependency) == nil {
			t.Fatal("accepted mismatched or replaced runtime")
		}
	}
	path := filepath.Join(t.TempDir(), "build.json")
	data := `{"runtime":{"repository":"https://github.com/wippyai/runtime.git","commit":"5eb9901870e3a7ca72b608fc0f5e70b531d914b6","go":"1.27.0","patches":[{}]}}`
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := nativeTestInputs(path); err == nil {
		t.Fatal("accepted a runtime patch")
	}
}
