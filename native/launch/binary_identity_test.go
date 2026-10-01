// SPDX-License-Identifier: MIT

package launch

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime/debug"
	"testing"
)

func TestBinaryIdentityUsesExecutableModuleVersions(t *testing.T) {
	facts := binaryIdentityFromBuildInfo(&debug.BuildInfo{Main: debug.Module{
		Path: "github.com/wippyai/runtime", Version: "(devel)",
	}, Deps: []*debug.Module{{
		Path: nativeModulePath, Version: "v1.2.3",
	}, {
		Path: "example.com/terminal", Version: "v4.5.6",
	}}})
	if facts.NativeModule != nativeModulePath || facts.NativeVersion != "v1.2.3" {
		t.Fatalf("native identity = %q@%q", facts.NativeModule, facts.NativeVersion)
	}
	if facts.NativeModules != `{"example.com/terminal":"v4.5.6","github.com/wippyai/bee/native":"v1.2.3","github.com/wippyai/runtime":"(devel)"}` {
		t.Fatalf("native module manifest = %s", facts.NativeModules)
	}
	if facts.RuntimeCommit != runtimeCommit {
		t.Fatalf("runtime commit = %q", facts.RuntimeCommit)
	}
}

func TestRuntimeCommitMatchesBeeBuildManifest(t *testing.T) {
	path := filepath.Join("..", "..", "wippy.build.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Runtime struct {
			Commit string `json:"commit"`
		} `json:"runtime"`
	}
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	if config.Runtime.Commit != runtimeCommit {
		t.Fatalf("baked runtime commit %q differs from manifest %q", runtimeCommit, config.Runtime.Commit)
	}
}
