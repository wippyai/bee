//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"github.com/wippyai/bee/native/client/hive"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	application "github.com/wippyai/runtime/api/application"
	"github.com/wippyai/runtime/application/statelock"
)

func TestProjectFoldersHaveIndependentRuntimeLocks(t *testing.T) {
	root := t.TempDir()
	first := filepath.Join(root, "first")
	second := filepath.Join(root, "second")
	for _, directory := range []string{first, second} {
		if err := os.Mkdir(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	base := application.LaunchRequest{Operation: application.RunApplication, Directory: first, StateDir: filepath.Join(root, "state")}
	a, err := SelectProject(base)
	if err != nil {
		t.Fatal(err)
	}
	base.Directory = second
	b, err := SelectProject(base)
	if err != nil {
		t.Fatal(err)
	}
	if a.StateDir == b.StateDir || a.Directory != first || b.Directory != second {
		t.Fatal(a, b)
	}
	for _, directory := range []string{a.StateDir, b.StateDir} {
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	unlock, err := statelock.Acquire(a.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	busy, err := ownerLockBusy(a.StateDir)
	if err != nil || !busy {
		t.Fatal("same folder must find existing node", busy, err)
	}
	busy, err = ownerLockBusy(b.StateDir)
	if err != nil || busy {
		t.Fatal("other folder must be free to start", busy, err)
	}
}

func TestProjectAliasesAndExplicitState(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(root, "project")
	alias := filepath.Join(root, "alias")
	if err := os.Mkdir(project, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(project, alias); err != nil {
		t.Skip(err)
	}
	request := application.LaunchRequest{Operation: application.RunApplication, Directory: project, StateDir: filepath.Join(root, "state")}
	direct, err := SelectProject(request)
	if err != nil {
		t.Fatal(err)
	}
	request.Directory = alias
	linked, err := SelectProject(request)
	if err != nil || linked.StateDir != direct.StateDir || linked.Directory != direct.Directory {
		t.Fatal(linked, direct, err)
	}
	request.StateDir = direct.StateDir
	request.ExplicitState = true
	child, err := SelectProject(request)
	if err != nil || child.StateDir != direct.StateDir {
		t.Fatal("explicit child state remapped", child, err)
	}
	request.ExplicitState = false
	request.Directory = filepath.Join(root, "absent")
	if _, err := SelectProject(request); err == nil {
		t.Fatal("missing project accepted")
	}
	for _, operation := range []application.Operation{application.RunRuntime, application.Update} {
		request.Operation = operation
		unchanged, err := SelectProject(request)
		if err != nil || unchanged.StateDir != request.StateDir {
			t.Fatal("tooling state changed", unchanged, err)
		}
	}
}

func TestExplicitClientNeverStartsProjectNode(t *testing.T) {
	request := application.LaunchRequest{Operation: application.RunApplication, Command: "bee", Directory: t.TempDir(), StateDir: t.TempDir()}
	client := Client{Command: "bee", Mode: hive.Control, AttachOnly: true, Stdin: os.Stdin, Stdout: io.Discard}
	err := client.Run(context.Background(), request)
	if err == nil || !strings.Contains(err.Error(), "No running Bee for this project") {
		t.Fatal(err)
	}
	files, err := os.ReadDir(request.StateDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		if strings.HasPrefix(file.Name(), "owner-") || strings.HasSuffix(file.Name(), ".db") {
			t.Fatal("display-only launch created node state", file.Name())
		}
	}
}
