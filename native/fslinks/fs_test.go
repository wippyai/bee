// SPDX-License-Identifier: MIT

package fslinks

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestSelectedExternalFile(t *testing.T) {
	base, target := t.TempDir(), t.TempDir()
	file := filepath.Join(target, "fixture.json")
	if err := os.WriteFile(file, []byte(`{"fixture":true}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(file, filepath.Join(base, "selected")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(file, filepath.Join(base, "unselected")); err != nil {
		t.Fatal(err)
	}
	volume, err := New(base, []Link{{Path: "selected", Write: true}})
	if err != nil {
		t.Fatal(err)
	}
	defer volume.Close()
	opened, err := volume.Open("selected")
	if err != nil {
		t.Fatalf("host-selected external link cannot be read: %v", err)
	}
	content, err := io.ReadAll(opened)
	opened.Close()
	if err != nil || string(content) != `{"fixture":true}` {
		t.Fatal("selected file differs")
	}
	if opened, err := volume.Open("unselected"); err == nil {
		opened.Close()
		t.Fatal("unselected link escaped its root")
	}
	if err := volume.WriteFileAtomic("selected", []byte("updated fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	content, err = os.ReadFile(file)
	if err != nil || string(content) != "updated fixture" {
		t.Fatal("selected physical file was not updated")
	}
	if info, err := os.Lstat(filepath.Join(base, "selected")); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("write-back replaced the host's selected symlink")
	}
}

func TestSelectedLinkPinsTargetAndRejectsReplacementLinks(t *testing.T) {
	base, first, second := t.TempDir(), t.TempDir(), t.TempDir()
	for _, folder := range []string{first, second} {
		if err := os.WriteFile(filepath.Join(folder, "fixture"), []byte(folder), 0600); err != nil {
			t.Fatal(err)
		}
	}
	selected := filepath.Join(base, "selected")
	if err := os.Symlink(filepath.Join(first, "fixture"), selected); err != nil {
		t.Fatal(err)
	}
	volume, err := New(base, []Link{{Path: "selected", Write: true}})
	if err != nil {
		t.Fatal(err)
	}
	defer volume.Close()
	if err := os.Remove(selected); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(second, "fixture"), selected); err != nil {
		t.Fatal(err)
	}
	opened, err := volume.Open("selected")
	if err != nil {
		t.Fatal(err)
	}
	content, err := io.ReadAll(opened)
	opened.Close()
	if err != nil || string(content) != first {
		t.Fatal("retargeting the declaration changed its pinned source")
	}
	if err := os.Remove(filepath.Join(first, "fixture")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(second, "fixture"), filepath.Join(first, "fixture")); err != nil {
		t.Fatal(err)
	}
	if opened, err := volume.Open("selected"); err == nil {
		opened.Close()
		t.Fatal("replacement link was followed")
	}
	if err := volume.WriteFileAtomic("selected", []byte("changed"), 0600); err == nil {
		t.Fatal("replacement link was overwritten")
	}
}

func TestSelectedReadOnlyAndMissingPaths(t *testing.T) {
	base := t.TempDir()
	if err := os.WriteFile(filepath.Join(base, "settings"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	volume, err := New(base, []Link{{Path: "settings"}, {Path: "absent", Write: true}})
	if err != nil {
		t.Fatal(err)
	}
	defer volume.Close()
	if err := volume.WriteFileAtomic("settings", []byte("changed"), 0600); !errors.Is(err, fs.ErrPermission) {
		t.Fatalf("read-only selected file: %v", err)
	}
	if _, err := volume.Open("absent"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing selected file: %v", err)
	}
	if err := volume.WriteFileAtomic("absent", []byte("new fixture"), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsInvalidSelectedPaths(t *testing.T) {
	base := t.TempDir()
	for _, name := range []string{"", ".", "..", "../outside", "/absolute", "a/../b", "a//b", "a\\b"} {
		volume, err := New(base, []Link{{Path: name}})
		if err == nil {
			volume.Close()
			t.Fatalf("invalid selected path accepted: %q", name)
		}
	}
}
