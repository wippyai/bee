//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/internal/privatefile"
	application "github.com/wippyai/runtime/api/application"
)

func TestProjectStateDirsAreDistinctAndCanonical(t *testing.T) {
	root := t.TempDir()
	first := filepath.Join(root, "first")
	second := filepath.Join(root, "second")
	for _, directory := range []string{first, second} {
		if err := os.Mkdir(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	a, err := ProjectStateDir(filepath.Join(root, "state"), first)
	if err != nil {
		t.Fatal(err)
	}
	b, err := ProjectStateDir(filepath.Join(root, "state"), second)
	if err != nil || a == b {
		t.Fatal(a, b, err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(first, alias); err != nil {
		t.Skip(err)
	}
	linked, err := ProjectStateDir(filepath.Join(root, "state"), alias)
	if err != nil || linked != a {
		t.Fatal(linked, a, err)
	}
}

func TestDefaultProjectStateDirLeavesFreshRootUnchanged(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	project := filepath.Join(t.TempDir(), "project")
	if err := os.Mkdir(project, 0700); err != nil {
		t.Fatal(err)
	}
	want, err := ProjectStateDir(root, project)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DefaultProjectStateDir(root, project)
	if err != nil || got != want {
		t.Fatal(got, want, err)
	}
	if _, err := os.Lstat(root); !os.IsNotExist(err) {
		t.Fatal("fresh selection created the shared root", err)
	}
}

func TestDefaultProjectStateDirBindsLegacyRootOnce(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	legacyRegistry := filepath.Join(root, "registry.db")
	if err := os.WriteFile(legacyRegistry, []byte("legacy bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	first := filepath.Join(t.TempDir(), "first")
	second := filepath.Join(t.TempDir(), "second")
	for _, directory := range []string{first, second} {
		if err := os.Mkdir(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	selected, err := DefaultProjectStateDir(root, first)
	if err != nil || selected != root {
		t.Fatal(selected, err)
	}
	again, err := DefaultProjectStateDir(root, first)
	if err != nil || again != root {
		t.Fatal(again, err)
	}
	wantSecond, err := ProjectStateDir(root, second)
	if err != nil {
		t.Fatal(err)
	}
	other, err := DefaultProjectStateDir(root, second)
	if err != nil || other != wantSecond {
		t.Fatal(other, wantSecond, err)
	}
	if data, err := os.ReadFile(legacyRegistry); err != nil || string(data) != "legacy bytes" {
		t.Fatal("legacy data changed", string(data), err)
	}

	receiptBytes, err := os.ReadFile(filepath.Join(root, legacyProjectFile))
	if err != nil {
		t.Fatal(err)
	}
	var receipt legacyProjectSelection
	if err := json.Unmarshal(receiptBytes, &receipt); err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(first)
	if err != nil || receipt.ProjectDir != canonical || receipt.StateDir != root || receipt.Mode != "legacy-root" {
		t.Fatal(receipt, err)
	}
}

func TestDefaultProjectStateDirConcurrentLegacyBindingHasOneOwner(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "workspace.db"), []byte("legacy"), 0600); err != nil {
		t.Fatal(err)
	}
	projects := make([]string, 8)
	for index := range projects {
		projects[index] = filepath.Join(t.TempDir(), "project")
		if err := os.Mkdir(projects[index], 0700); err != nil {
			t.Fatal(err)
		}
	}

	results := make([]string, len(projects))
	errors := make([]error, len(projects))
	start := make(chan struct{})
	var group sync.WaitGroup
	for index := range projects {
		group.Add(1)
		go func(index int) {
			defer group.Done()
			<-start
			results[index], errors[index] = DefaultProjectStateDir(root, projects[index])
		}(index)
	}
	close(start)
	group.Wait()

	legacyOwners := 0
	for index, result := range results {
		if errors[index] != nil {
			t.Fatal(errors[index])
		}
		if result == root {
			legacyOwners++
			continue
		}
		want, err := ProjectStateDir(root, projects[index])
		if err != nil || result != want {
			t.Fatal(index, result, want, err)
		}
	}
	if legacyOwners != 1 {
		t.Fatal("legacy owner count", legacyOwners, results)
	}
}

func TestDefaultProjectStateDirRejectsMalformedReceipt(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	project := filepath.Join(t.TempDir(), "project")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(project, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, legacyProjectFile), []byte(`{"version":1,"mode":"legacy-root","project_dir":"/tmp/project","state_dir":"/tmp/state","extra":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := DefaultProjectStateDir(root, project); err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatal(err)
	}
}

func TestDefaultProjectStateDirRecognizesEveryLegacyStore(t *testing.T) {
	for _, marker := range []string{
		"approvals.db", "artifact-cache", "credentials.db", "deployment",
		"gateway.db", "governance.db", "local-mesh", "node.db", "placement",
		"placement.db", "registry.db", "resources.db", "threads.db",
		"workspace.db", "workspace.db.client",
	} {
		t.Run(marker, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "state")
			project := filepath.Join(t.TempDir(), "project")
			if err := os.Mkdir(root, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.Mkdir(project, 0700); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(root, marker)
			if strings.Contains(marker, "-") || marker == "deployment" || marker == "placement" {
				if err := os.Mkdir(path, 0700); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(path, []byte("legacy"), 0600); err != nil {
				t.Fatal(err)
			}
			selected, err := DefaultProjectStateDir(root, project)
			if err != nil || selected != root {
				t.Fatal(selected, err)
			}
		})
	}
}

func TestDefaultProjectStateDirRefusesRunningLegacyOwner(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	project := filepath.Join(t.TempDir(), "project")
	if err := os.Mkdir(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(project, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "threads.db"), []byte("legacy"), 0600); err != nil {
		t.Fatal(err)
	}
	release, err := privatefile.TryLock(context.Background(), root, applicationLock)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if _, err := DefaultProjectStateDir(root, project); err == nil || !strings.Contains(err.Error(), "legacy Bee is running") {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(root, legacyProjectFile)); !os.IsNotExist(err) {
		t.Fatal("running owner published project binding", err)
	}
}

func TestCanonicalProjectDoesNotRedirectRuntimeState(t *testing.T) {
	root := t.TempDir()
	request := application.LaunchRequest{Directory: root, StateDir: filepath.Join(root, "state")}
	selected, err := CanonicalProject(request)
	if err != nil || selected.StateDir != request.StateDir || selected.Directory != root {
		t.Fatal(selected, err)
	}
}

func TestExplicitClientNeverStartsProjectNode(t *testing.T) {
	request := application.LaunchRequest{Operation: application.RunApplication, Command: "bee", Directory: t.TempDir(), StateDir: t.TempDir()}
	client := Client{Command: "bee", Mode: hive.Control, AttachOnly: true, Stdin: os.Stdin, Stdout: io.Discard}
	err := client.Run(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "No running Bee for this project") {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(request.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatal("display-only launch created state", entries)
	}
}
