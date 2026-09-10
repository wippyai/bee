// SPDX-License-Identifier: MIT

package config

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func testAbsPath(p string) string {
	if runtime.GOOS == "windows" {
		vol := filepath.VolumeName(os.TempDir())
		if vol == "" {
			vol = "C:"
		}
		return filepath.Clean(vol + filepath.FromSlash(p))
	}
	return filepath.Clean(p)
}

func newTestDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "confstore")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestRoundtripSeparateReopen(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)

	store1, err := New(dir)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}

	p1 := testAbsPath("/projects/alpha")
	s1 := testAbsPath("/state/alpha")
	p2 := testAbsPath("/projects/beta")
	s2 := testAbsPath("/state/beta")

	committed1, err := store1.Update(ctx, 0, func(doc Document) (Document, error) {
		doc.EnrollmentRef = "enrollment-ref-xyz"
		doc.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "ws-alpha", ProjectDir: p1, RuntimeStateDir: s1},
			{WorkspaceID: "ws-beta", ProjectDir: p2, RuntimeStateDir: s2},
		}
		return doc, nil
	})
	if err != nil {
		t.Fatalf("Update revision 0 failed: %v", err)
	}

	if committed1.Version != 1 {
		t.Fatalf("expected version 1, got %d", committed1.Version)
	}
	if committed1.Revision != 1 {
		t.Fatalf("expected revision 1, got %d", committed1.Revision)
	}
	if committed1.EnrollmentRef != "enrollment-ref-xyz" {
		t.Fatalf("unexpected enrollment ref %q", committed1.EnrollmentRef)
	}
	if len(committed1.Workspaces) != 2 {
		t.Fatalf("expected 2 workspaces, got %d", len(committed1.Workspaces))
	}

	// Separate reopen: new Store instance
	store2, err := New(dir)
	if err != nil {
		t.Fatalf("New on store2 failed: %v", err)
	}

	doc2, err := store2.Read(ctx)
	if err != nil {
		t.Fatalf("store2 Read failed: %v", err)
	}
	if doc2.Version != 1 || doc2.Revision != 1 || doc2.EnrollmentRef != "enrollment-ref-xyz" {
		t.Fatalf("reopened doc mismatch: %+v", doc2)
	}
	if len(doc2.Workspaces) != 2 {
		t.Fatalf("reopened doc workspaces length mismatch: %d", len(doc2.Workspaces))
	}

	// Update on store2 to revision 2
	p3 := testAbsPath("/projects/alpha-alias")
	committed2, err := store2.Update(ctx, 1, func(doc Document) (Document, error) {
		doc.Workspaces = append(doc.Workspaces, WorkspaceLocation{
			WorkspaceID:     "ws-alpha",
			ProjectDir:      p3,
			RuntimeStateDir: s1, // agrees on state dir with ws-alpha
		})
		return doc, nil
	})
	if err != nil {
		t.Fatalf("Update revision 1 failed: %v", err)
	}
	if committed2.Revision != 2 {
		t.Fatalf("expected revision 2, got %d", committed2.Revision)
	}
	if len(committed2.Workspaces) != 3 {
		t.Fatalf("expected 3 workspaces, got %d", len(committed2.Workspaces))
	}

	// Third reopen
	store3, err := New(dir)
	if err != nil {
		t.Fatalf("New on store3 failed: %v", err)
	}
	doc3, err := store3.Read(ctx)
	if err != nil {
		t.Fatalf("store3 Read failed: %v", err)
	}
	if doc3.Revision != 2 || len(doc3.Workspaces) != 3 {
		t.Fatalf("store3 doc mismatch: %+v", doc3)
	}
}

func TestEmptyMissingReadsDontCreate(t *testing.T) {
	ctx := context.Background()

	// Case 1: Directory does not exist
	nonexistentDir := filepath.Join(t.TempDir(), "missing-dir")
	store, err := New(nonexistentDir)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}
	_, err = store.Read(ctx)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected os.ErrNotExist, got %v", err)
	}
	if _, err := os.Lstat(nonexistentDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing directory was created by Read: %v", err)
	}

	// Case 2: Directory exists, config.json missing
	dir := newTestDir(t)
	store2, err := New(dir)
	if err != nil {
		t.Fatalf("New failed: %v", err)
	}
	_, err = store2.Read(ctx)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected os.ErrNotExist, got %v", err)
	}
	docPath := filepath.Join(dir, ConfigFileName)
	if _, err := os.Lstat(docPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("config.json was created by Read: %v", err)
	}
	lockPath := filepath.Join(dir, LockFileName)
	if _, err := os.Lstat(lockPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf(".config.lock was created by Read: %v", err)
	}

	// Case 3: config.json exists but is 0 bytes (empty)
	if err := os.WriteFile(docPath, []byte{}, 0600); err != nil {
		t.Fatal(err)
	}
	_, err = store2.Read(ctx)
	if !errors.Is(err, ErrMalformedDocument) {
		t.Fatalf("expected ErrMalformedDocument on empty file, got %v", err)
	}
	fi, err := os.Lstat(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() != 0 {
		t.Fatalf("empty file was mutated by Read: size %d", fi.Size())
	}
}

func TestConcurrentSameRevisionUpdatesOneCommitOneConflict(t *testing.T) {
	ctx := context.Background()

	// Test 1: Concurrent creation from missing state (expectedRevision 0)
	t.Run("CreateRevision0", func(t *testing.T) {
		dir := newTestDir(t)
		const concurrency = 10
		var wg sync.WaitGroup
		successCount := 0
		conflictCount := 0
		var mu sync.Mutex

		for i := 0; i < concurrency; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				store, err := New(dir)
				if err != nil {
					t.Errorf("New failed: %v", err)
					return
				}
				p := testAbsPath(fmt.Sprintf("/projects/worker-%d", idx))
				s := testAbsPath(fmt.Sprintf("/state/worker-%d", idx))
				_, err = store.Update(ctx, 0, func(doc Document) (Document, error) {
					doc.Workspaces = []WorkspaceLocation{
						{WorkspaceID: fmt.Sprintf("ws-%d", idx), ProjectDir: p, RuntimeStateDir: s},
					}
					return doc, nil
				})
				mu.Lock()
				defer mu.Unlock()
				if err == nil {
					successCount++
				} else if errors.Is(err, ErrConflict) {
					conflictCount++
				} else {
					t.Errorf("unexpected error: %v", err)
				}
			}(i)
		}
		wg.Wait()

		if successCount != 1 {
			t.Fatalf("expected exactly 1 commit, got %d", successCount)
		}
		if conflictCount != concurrency-1 {
			t.Fatalf("expected %d conflicts, got %d", concurrency-1, conflictCount)
		}

		store, err := New(dir)
		if err != nil {
			t.Fatal(err)
		}
		doc, err := store.Read(ctx)
		if err != nil {
			t.Fatalf("Read failed: %v", err)
		}
		if doc.Revision != 1 {
			t.Fatalf("expected revision 1, got %d", doc.Revision)
		}
	})

	// Test 2: Concurrent update from existing revision 1
	t.Run("UpdateRevision1", func(t *testing.T) {
		dir := newTestDir(t)
		store, err := New(dir)
		if err != nil {
			t.Fatal(err)
		}

		// Initial commit (Revision 1)
		_, err = store.Update(ctx, 0, func(doc Document) (Document, error) {
			doc.EnrollmentRef = "initial"
			return doc, nil
		})
		if err != nil {
			t.Fatalf("initial Update failed: %v", err)
		}

		const concurrency = 10
		var wg sync.WaitGroup
		successCount := 0
		conflictCount := 0
		var mu sync.Mutex

		for i := 0; i < concurrency; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				s, err := New(dir)
				if err != nil {
					t.Errorf("New failed: %v", err)
					return
				}
				_, err = s.Update(ctx, 1, func(doc Document) (Document, error) {
					doc.EnrollmentRef = fmt.Sprintf("worker-%d", idx)
					return doc, nil
				})
				mu.Lock()
				defer mu.Unlock()
				if err == nil {
					successCount++
				} else if errors.Is(err, ErrConflict) {
					conflictCount++
				} else {
					t.Errorf("unexpected error: %v", err)
				}
			}(i)
		}
		wg.Wait()

		if successCount != 1 {
			t.Fatalf("expected exactly 1 commit, got %d", successCount)
		}
		if conflictCount != concurrency-1 {
			t.Fatalf("expected %d conflicts, got %d", concurrency-1, conflictCount)
		}

		finalDoc, err := store.Read(ctx)
		if err != nil {
			t.Fatalf("Read failed: %v", err)
		}
		if finalDoc.Revision != 2 {
			t.Fatalf("expected revision 2, got %d", finalDoc.Revision)
		}
	})
}

func TestStaleRejectionPreservesPriorBytesAndSkipsCallback(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	p1 := testAbsPath("/projects/test1")
	s1 := testAbsPath("/state/test1")

	_, err = store.Update(ctx, 0, func(doc Document) (Document, error) {
		doc.EnrollmentRef = "original"
		doc.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "ws1", ProjectDir: p1, RuntimeStateDir: s1},
		}
		return doc, nil
	})
	if err != nil {
		t.Fatalf("seed update failed: %v", err)
	}

	docPath := filepath.Join(dir, ConfigFileName)
	priorBytes, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}

	// 1. Stale revision (expectedRevision 0 when stored is 1)
	callbackCalled := false
	_, err = store.Update(ctx, 0, func(doc Document) (Document, error) {
		callbackCalled = true
		return doc, nil
	})
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict, got %v", err)
	}
	if callbackCalled {
		t.Fatal("callback was executed for stale revision")
	}
	afterBytes, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(priorBytes, afterBytes) {
		t.Fatal("file bytes mutated after stale revision rejected")
	}

	// 2. Future revision (expectedRevision 2 when stored is 1)
	callbackCalled = false
	_, err = store.Update(ctx, 2, func(doc Document) (Document, error) {
		callbackCalled = true
		return doc, nil
	})
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict, got %v", err)
	}
	if callbackCalled {
		t.Fatal("callback was executed for wrong revision")
	}
	afterBytes, err = os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(priorBytes, afterBytes) {
		t.Fatal("file bytes mutated after future revision rejected")
	}

	// 3. Stale revision on missing file
	dirMissing := newTestDir(t)
	storeMissing, err := New(dirMissing)
	if err != nil {
		t.Fatal(err)
	}
	callbackCalled = false
	_, err = storeMissing.Update(ctx, 1, func(doc Document) (Document, error) {
		callbackCalled = true
		return doc, nil
	})
	if !errors.Is(err, ErrConflict) {
		t.Fatalf("expected ErrConflict on missing file with expectedRevision 1, got %v", err)
	}
	if callbackCalled {
		t.Fatal("callback was executed on missing file with wrong revision")
	}
	if _, err := os.Lstat(filepath.Join(dirMissing, ConfigFileName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("file was created when update failed on conflict")
	}
}

func TestCorruptUnknownDuplicateCaseAliasNullMissingRejection(t *testing.T) {
	ctx := context.Background()

	validP := testAbsPath("/valid/project")
	validS := testAbsPath("/valid/state")

	testCases := []struct {
		name    string
		payload string
	}{
		{"corrupt_json", `{"version": 1, "revision": 1, malformed`},
		{"empty_object", `{}`},
		{"unknown_field_root", `{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [], "unknown_field": 123}`},
		{"case_alias_version", `{"Version": 1, "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"case_alias_revision", `{"version": 1, "Revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"case_alias_enrollment", `{"version": 1, "revision": 1, "enrollmentRef": "", "workspaces": []}`},
		{"case_alias_workspaces", `{"version": 1, "revision": 1, "enrollment_ref": "", "Workspaces": []}`},
		{"duplicate_version", `{"version": 1, "version": 1, "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"duplicate_revision", `{"version": 1, "revision": 1, "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"duplicate_enrollment", `{"version": 1, "revision": 1, "enrollment_ref": "", "enrollment_ref": "", "workspaces": []}`},
		{"duplicate_workspaces", `{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [], "workspaces": []}`},
		{"null_version", `{"version": null, "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"null_revision", `{"version": 1, "revision": null, "enrollment_ref": "", "workspaces": []}`},
		{"null_enrollment", `{"version": 1, "revision": 1, "enrollment_ref": null, "workspaces": []}`},
		{"null_workspaces", `{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": null}`},
		{"missing_version", `{"revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"missing_revision", `{"version": 1, "enrollment_ref": "", "workspaces": []}`},
		{"missing_enrollment", `{"version": 1, "revision": 1, "workspaces": []}`},
		{"missing_workspaces", `{"version": 1, "revision": 1, "enrollment_ref": ""}`},
		{"version_is_zero", `{"version": 0, "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"version_is_two", `{"version": 2, "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"version_is_string", `{"version": "1", "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"version_is_float", `{"version": 1.0, "revision": 1, "enrollment_ref": "", "workspaces": []}`},
		{"revision_is_zero_on_disk", `{"version": 1, "revision": 0, "enrollment_ref": "", "workspaces": []}`},
		{"revision_is_negative", `{"version": 1, "revision": -1, "enrollment_ref": "", "workspaces": []}`},
		{"revision_is_string", `{"version": 1, "revision": "1", "enrollment_ref": "", "workspaces": []}`},
		{"revision_is_float", `{"version": 1, "revision": 1.5, "enrollment_ref": "", "workspaces": []}`},
		{"trailing_content", `{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": []} extra`},
		{"trailing_json", `{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": []} {"extra": 1}`},
		{"workspace_null_entry", `{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [null]}`},
		{"workspace_string_entry", `{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": ["string"]}`},
		{"workspace_unknown_field", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","project_dir":"%s","runtime_state_dir":"%s","unknown":1}]}`, validP, validS)},
		{"workspace_case_alias_id", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspaceId":"ws","project_dir":"%s","runtime_state_dir":"%s"}]}`, validP, validS)},
		{"workspace_case_alias_project", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","projectDir":"%s","runtime_state_dir":"%s"}]}`, validP, validS)},
		{"workspace_case_alias_state", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","project_dir":"%s","stateDir":"%s"}]}`, validP, validS)},
		{"workspace_duplicate_field", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","workspace_id":"ws","project_dir":"%s","runtime_state_dir":"%s"}]}`, validP, validS)},
		{"workspace_null_id", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":null,"project_dir":"%s","runtime_state_dir":"%s"}]}`, validP, validS)},
		{"workspace_null_project", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","project_dir":null,"runtime_state_dir":"%s"}]}`, validS)},
		{"workspace_null_state", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","project_dir":"%s","runtime_state_dir":null}]}`, validP)},
		{"workspace_missing_id", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"project_dir":"%s","runtime_state_dir":"%s"}]}`, validP, validS)},
		{"workspace_missing_project", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","runtime_state_dir":"%s"}]}`, validS)},
		{"workspace_missing_state", fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [{"workspace_id":"ws","project_dir":"%s"}]}`, validP)},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			dir := newTestDir(t)
			docPath := filepath.Join(dir, ConfigFileName)
			if err := os.WriteFile(docPath, []byte(tc.payload), 0600); err != nil {
				t.Fatal(err)
			}

			store, err := New(dir)
			if err != nil {
				t.Fatal(err)
			}

			// 1. Read must reject
			_, err = store.Read(ctx)
			if !errors.Is(err, ErrMalformedDocument) {
				t.Fatalf("Read: expected ErrMalformedDocument for %s, got %v", tc.name, err)
			}

			// 2. Update must reject without calling callback and preserve bytes
			callbackCalled := false
			_, err = store.Update(ctx, 1, func(doc Document) (Document, error) {
				callbackCalled = true
				return doc, nil
			})
			if !errors.Is(err, ErrMalformedDocument) {
				t.Fatalf("Update: expected ErrMalformedDocument for %s, got %v", tc.name, err)
			}
			if callbackCalled {
				t.Fatalf("callback was called for malformed file %s", tc.name)
			}

			afterBytes, err := os.ReadFile(docPath)
			if err != nil {
				t.Fatal(err)
			}
			if string(afterBytes) != tc.payload {
				t.Fatalf("bytes mutated for %s", tc.name)
			}
		})
	}
}

func TestTransformFailurePreservesBytes(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	p1 := testAbsPath("/projects/seed")
	s1 := testAbsPath("/state/seed")

	_, err = store.Update(ctx, 0, func(doc Document) (Document, error) {
		doc.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "ws-seed", ProjectDir: p1, RuntimeStateDir: s1},
		}
		return doc, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	docPath := filepath.Join(dir, ConfigFileName)
	priorBytes, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}

	expectedErr := errors.New("deliberate transform failure")
	_, err = store.Update(ctx, 1, func(doc Document) (Document, error) {
		return Document{}, expectedErr
	})
	if !errors.Is(err, expectedErr) {
		t.Fatalf("expected transform error, got %v", err)
	}

	afterBytes, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(priorBytes, afterBytes) {
		t.Fatal("prior bytes mutated on transform failure")
	}
}

func TestInvalidIndexPreservesBytes(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	p1 := testAbsPath("/projects/p1")
	s1 := testAbsPath("/state/s1")
	p2 := testAbsPath("/projects/p2")
	s2 := testAbsPath("/state/s2")

	_, err = store.Update(ctx, 0, func(doc Document) (Document, error) {
		doc.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "ws1", ProjectDir: p1, RuntimeStateDir: s1},
		}
		return doc, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	docPath := filepath.Join(dir, ConfigFileName)
	priorBytes, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}

	badTransforms := []struct {
		name string
		fn   func(Document) (Document, error)
	}{
		{
			name: "duplicate_project_dir",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "ws2",
					ProjectDir:      p1, // duplicate of p1
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "inconsistent_runtime_state_dir_for_workspace",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "ws1", // ws1 already mapped to s1
					ProjectDir:      p2,
					RuntimeStateDir: s2, // conflicting state dir s2
				})
				return d, nil
			},
		},
		{
			name: "empty_workspace_id",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "",
					ProjectDir:      p2,
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "workspace_id_too_long",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     strings.Repeat("x", 161),
					ProjectDir:      p2,
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "workspace_id_control_char",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "ws\n",
					ProjectDir:      p2,
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "project_dir_relative",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "ws2",
					ProjectDir:      "relative/path",
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "project_dir_unclean",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "ws2",
					ProjectDir:      p2 + "/.",
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "project_dir_control_char",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "ws2",
					ProjectDir:      p2 + "\x00",
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "project_dir_too_long",
			fn: func(d Document) (Document, error) {
				d.Workspaces = append(d.Workspaces, WorkspaceLocation{
					WorkspaceID:     "ws2",
					ProjectDir:      testAbsPath("/p/" + strings.Repeat("a", 4096)),
					RuntimeStateDir: s2,
				})
				return d, nil
			},
		},
		{
			name: "enrollment_ref_too_long",
			fn: func(d Document) (Document, error) {
				d.EnrollmentRef = strings.Repeat("e", 161)
				return d, nil
			},
		},
		{
			name: "enrollment_ref_control_char",
			fn: func(d Document) (Document, error) {
				d.EnrollmentRef = "enroll\x1b"
				return d, nil
			},
		},
		{
			name: "metadata_version_change",
			fn: func(d Document) (Document, error) {
				d.Version = 2
				return d, nil
			},
		},
		{
			name: "metadata_revision_change",
			fn: func(d Document) (Document, error) {
				d.Revision = 999
				return d, nil
			},
		},
	}

	for _, bt := range badTransforms {
		t.Run(bt.name, func(t *testing.T) {
			_, err := store.Update(ctx, 1, bt.fn)
			if err == nil {
				t.Fatalf("expected error for %s, got nil", bt.name)
			}
			afterBytes, err := os.ReadFile(docPath)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(priorBytes, afterBytes) {
				t.Fatalf("bytes mutated for %s", bt.name)
			}
		})
	}
}

func TestManyWorkspaceAliasInvariants(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	sAlpha := testAbsPath("/state/alpha")
	sBeta := testAbsPath("/state/beta")

	// 1. One WorkspaceID with multiple ProjectDirs, agreeing on RuntimeStateDir -> Valid!
	// Two folders referring to same workspace -> Valid!
	doc1, err := store.Update(ctx, 0, func(doc Document) (Document, error) {
		doc.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "ws-alpha", ProjectDir: testAbsPath("/projects/folder1"), RuntimeStateDir: sAlpha},
			{WorkspaceID: "ws-alpha", ProjectDir: testAbsPath("/projects/folder2"), RuntimeStateDir: sAlpha},
			{WorkspaceID: "ws-alpha", ProjectDir: testAbsPath("/projects/folder3"), RuntimeStateDir: sAlpha},
			{WorkspaceID: "ws-beta", ProjectDir: testAbsPath("/projects/folder4"), RuntimeStateDir: sBeta},
			{WorkspaceID: "ws-beta", ProjectDir: testAbsPath("/projects/folder5"), RuntimeStateDir: sBeta},
		}
		return doc, nil
	})
	if err != nil {
		t.Fatalf("Update with valid aliases failed: %v", err)
	}
	if len(doc1.Workspaces) != 5 {
		t.Fatalf("expected 5 workspaces, got %d", len(doc1.Workspaces))
	}

	// 2. Bound of 4096 entries -> Valid!
	dirLarge := newTestDir(t)
	storeLarge, err := New(dirLarge)
	if err != nil {
		t.Fatal(err)
	}

	docLarge, err := storeLarge.Update(ctx, 0, func(doc Document) (Document, error) {
		ws := make([]WorkspaceLocation, MaxWorkspaces)
		for i := 0; i < MaxWorkspaces; i++ {
			ws[i] = WorkspaceLocation{
				WorkspaceID:     fmt.Sprintf("ws-%d", i),
				ProjectDir:      testAbsPath(fmt.Sprintf("/large/proj/%d", i)),
				RuntimeStateDir: testAbsPath(fmt.Sprintf("/large/state/%d", i)),
			}
		}
		doc.Workspaces = ws
		return doc, nil
	})
	if err != nil {
		t.Fatalf("Update with 4096 entries failed: %v", err)
	}
	if len(docLarge.Workspaces) != MaxWorkspaces {
		t.Fatalf("expected %d entries, got %d", MaxWorkspaces, len(docLarge.Workspaces))
	}

	// 3. 4097 entries -> Rejected!
	_, err = storeLarge.Update(ctx, 1, func(doc Document) (Document, error) {
		doc.Workspaces = append(doc.Workspaces, WorkspaceLocation{
			WorkspaceID:     "ws-overflow",
			ProjectDir:      testAbsPath("/large/proj/overflow"),
			RuntimeStateDir: testAbsPath("/large/state/overflow"),
		})
		return doc, nil
	})
	if !errors.Is(err, ErrMalformedDocument) {
		t.Fatalf("expected ErrMalformedDocument for 4097 entries, got %v", err)
	}
}

func TestRevisionOverflow(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	docPath := filepath.Join(dir, ConfigFileName)

	raw := fmt.Sprintf(`{
  "version": 1,
  "revision": %d,
  "enrollment_ref": "",
  "workspaces": []
}
`, uint64(math.MaxUint64))

	if err := os.WriteFile(docPath, []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}

	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	doc, err := store.Read(ctx)
	if err != nil {
		t.Fatalf("Read max uint64 revision failed: %v", err)
	}
	if doc.Revision != math.MaxUint64 {
		t.Fatalf("expected max uint64, got %d", doc.Revision)
	}

	// Attempting to update max uint64 must fail with ErrRevisionOverflow
	_, err = store.Update(ctx, math.MaxUint64, func(d Document) (Document, error) {
		d.EnrollmentRef = "overflow-attempt"
		return d, nil
	})
	if !errors.Is(err, ErrRevisionOverflow) {
		t.Fatalf("expected ErrRevisionOverflow, got %v", err)
	}

	// Verify bytes preserved
	afterBytes, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(afterBytes) != raw {
		t.Fatal("file bytes mutated after revision overflow rejection")
	}
}

func TestSnapshotsNotSliceAliased(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	p1 := testAbsPath("/projects/p1")
	s1 := testAbsPath("/state/s1")

	// Phase 1: Verify transform input slice is cloned and caller mutation does not leak
	var retainedInputSlice []WorkspaceLocation
	_, err = store.Update(ctx, 0, func(doc Document) (Document, error) {
		doc.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "ws1", ProjectDir: p1, RuntimeStateDir: s1},
		}
		return doc, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	committed2, err := store.Update(ctx, 1, func(doc Document) (Document, error) {
		retainedInputSlice = doc.Workspaces
		return doc, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Mutate the leaked input slice
	retainedInputSlice[0].ProjectDir = testAbsPath("/projects/corrupted")

	// Verify committed2 has not changed
	if committed2.Workspaces[0].ProjectDir != p1 {
		t.Fatalf("committed2 Workspaces mutated via leaked input slice: got %s", committed2.Workspaces[0].ProjectDir)
	}

	// Verify on-disk Read has not changed
	docRead, err := store.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if docRead.Workspaces[0].ProjectDir != p1 {
		t.Fatalf("on-disk Workspaces mutated via leaked input slice: got %s", docRead.Workspaces[0].ProjectDir)
	}

	// Phase 2: Caller mutates the returned committed document Workspaces
	committed2.Workspaces[0].ProjectDir = testAbsPath("/projects/corrupted2")
	docRead2, err := store.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if docRead2.Workspaces[0].ProjectDir != p1 {
		t.Fatalf("on-disk Workspaces mutated via committed struct slice: got %s", docRead2.Workspaces[0].ProjectDir)
	}
}

func TestNilCallbackRejectsWithoutFileCreation(t *testing.T) {
	ctx := context.Background()
	dir := filepath.Join(t.TempDir(), "no-create")

	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	_, err = store.Update(ctx, 0, nil)
	if err == nil {
		t.Fatal("expected error for nil transform, got nil")
	}

	if _, err := os.Lstat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("directory was created when transform was nil")
	}
}

func TestDocumentSizeLimit(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	docPath := filepath.Join(dir, ConfigFileName)

	// Create a document larger than 4 MiB
	hugeData := make([]byte, MaxDocumentBytes+1024)
	copy(hugeData, `{"version": 1, "revision": 1, "enrollment_ref": "`)
	for i := 49; i < len(hugeData)-25; i++ {
		hugeData[i] = 'a'
	}
	copy(hugeData[len(hugeData)-25:], `", "workspaces": []}`)

	if err := os.WriteFile(docPath, hugeData, 0600); err != nil {
		t.Fatal(err)
	}

	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	_, err = store.Read(ctx)
	if err == nil {
		t.Fatal("oversized document was accepted")
	}

	callbackCalled := false
	_, err = store.Update(ctx, 1, func(d Document) (Document, error) {
		callbackCalled = true
		return d, nil
	})
	if err == nil {
		t.Fatal("oversized document was accepted by Update")
	}
	if callbackCalled {
		t.Fatal("callback called on oversized doc")
	}
}

func TestErrorMessageSanitization(t *testing.T) {
	ctx := context.Background()
	dir := newTestDir(t)
	store, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}

	secretKey := "my_secret_token_12345"
	secretPath := testAbsPath("/very/secret/path/to/my/private/keys")

	// 1. Unknown field with secret key name
	rawUnknown := fmt.Sprintf(`{"version": 1, "revision": 1, "enrollment_ref": "", "workspaces": [], "%s": "val"}`, secretKey)
	docPath := filepath.Join(dir, ConfigFileName)
	if err := os.WriteFile(docPath, []byte(rawUnknown), 0600); err != nil {
		t.Fatal(err)
	}

	_, err = store.Read(ctx)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if strings.Contains(err.Error(), secretKey) {
		t.Fatalf("error message leaked secret key: %s", err.Error())
	}

	// 2. Secret value in malformed path
	_, err = store.Update(ctx, 0, func(d Document) (Document, error) {
		d.Workspaces = []WorkspaceLocation{
			{WorkspaceID: "ws1", ProjectDir: secretPath + "/.", RuntimeStateDir: secretPath},
		}
		return d, nil
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if strings.Contains(err.Error(), secretPath) {
		t.Fatalf("error message leaked secret path: %s", err.Error())
	}
}
