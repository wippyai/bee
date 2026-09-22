// SPDX-License-Identifier: MIT

package privatefile

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func privateTestDir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "store")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestSubprocessAtomicUpdateHelper(t *testing.T) {
	if os.Getenv("TEST_SUBPROCESS_PRIVATEFILE_UPDATE") != "1" {
		return
	}
	dir := os.Getenv("TEST_SUBPROCESS_PRIVATEFILE_DIR")
	doc := os.Getenv("TEST_SUBPROCESS_PRIVATEFILE_DOC")
	lock := os.Getenv("TEST_SUBPROCESS_PRIVATEFILE_LOCK")
	workerID := os.Getenv("TEST_SUBPROCESS_PRIVATEFILE_WORKER")
	if dir == "" || doc == "" || lock == "" || workerID == "" {
		fmt.Fprintln(os.Stderr, "missing required subprocess environment variables")
		os.Exit(2)
	}

	f, err := New(dir, doc, lock)
	if err != nil {
		fmt.Fprintf(os.Stderr, "New failed: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const iterations = 5
	for iter := 0; iter < iterations; iter++ {
		entry := fmt.Sprintf("worker-%s-iter-%d", workerID, iter)
		err := f.ReadModifyWrite(ctx, 128*1024, func(existing []byte) ([]byte, error) {
			lines := strings.Split(string(existing), "\n")
			var out []string
			for _, l := range lines {
				l = strings.TrimSpace(l)
				if l != "" {
					out = append(out, l)
				}
			}
			out = append(out, entry)
			return []byte(strings.Join(out, "\n") + "\n"), nil
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "ReadModifyWrite iter %d failed: %v\n", iter, err)
			os.Exit(1)
		}
	}

	os.Exit(0)
}

func TestSubprocessConcurrentAtomicUpdate(t *testing.T) {
	parent := t.TempDir()
	dir := filepath.Join(parent, "private_store")
	const (
		docName    = "counters.txt"
		lockName   = ".counters.lock"
		workers    = 8
		iterations = 5
	)

	var wg sync.WaitGroup
	errs := make([]error, workers)

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(workerIdx int) {
			defer wg.Done()

			cmd := exec.Command(os.Args[0], "-test.run=^TestSubprocessAtomicUpdateHelper$")
			cmd.Env = append(os.Environ(),
				"TEST_SUBPROCESS_PRIVATEFILE_UPDATE=1",
				"TEST_SUBPROCESS_PRIVATEFILE_DIR="+dir,
				"TEST_SUBPROCESS_PRIVATEFILE_DOC="+docName,
				"TEST_SUBPROCESS_PRIVATEFILE_LOCK="+lockName,
				"TEST_SUBPROCESS_PRIVATEFILE_WORKER="+strconv.Itoa(workerIdx),
			)

			out, err := cmd.CombinedOutput()
			if err != nil {
				errs[workerIdx] = fmt.Errorf("worker %d failed: %w (output: %s)", workerIdx, err, string(out))
			}
		}(i)
	}

	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("worker %d error: %v", i, err)
		}
	}

	docPath := filepath.Join(dir, docName)
	data, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatalf("read doc file: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	expectedCount := workers * iterations
	if len(lines) != expectedCount {
		t.Fatalf("expected %d entries, got %d: %v", expectedCount, len(lines), lines)
	}

	sort.Strings(lines)
	seen := make(map[string]bool)
	for _, l := range lines {
		if seen[l] {
			t.Fatalf("duplicate entry found: %s", l)
		}
		seen[l] = true
	}

	for w := 0; w < workers; w++ {
		for it := 0; it < iterations; it++ {
			expected := fmt.Sprintf("worker-%d-iter-%d", w, it)
			if !seen[expected] {
				t.Fatalf("missing expected entry: %s", expected)
			}
		}
	}

	fi, err := os.Stat(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if !fi.Mode().IsRegular() {
		t.Fatalf("document file is not regular: %s", fi.Mode())
	}
	if runtime.GOOS != "windows" && fi.Mode().Perm() != 0600 {
		t.Fatalf("document file permissions are %04o, want 0600", fi.Mode().Perm())
	}

	lockFi, err := os.Stat(filepath.Join(dir, lockName))
	if err != nil {
		t.Fatal(err)
	}
	if !lockFi.Mode().IsRegular() {
		t.Fatalf("lock file is not regular: %s", lockFi.Mode())
	}
}

func TestBasenameValidation(t *testing.T) {
	validDir := privateTestDir(t)

	testCases := []struct {
		name    string
		dir     string
		doc     string
		lock    string
		wantErr string
	}{
		{"EmptyDir", "", "doc", "lock", "directory path is required"},
		{"WhitespaceDir", "   ", "doc", "lock", "directory path is required"},
		{"EmptyDoc", validDir, "", "lock", "name cannot be empty"},
		{"EmptyLock", validDir, "doc", "", "name cannot be empty"},
		{"DotDoc", validDir, ".", "lock", "not a valid filename"},
		{"DotDotDoc", validDir, "..", "lock", "not a valid filename"},
		{"DotLock", validDir, "doc", ".", "not a valid filename"},
		{"DotDotLock", validDir, "doc", "..", "not a valid filename"},
		{"SlashInDoc", validDir, "foo/bar", "lock", "contains path separators"},
		{"BackslashInDoc", validDir, "foo\\bar", "lock", "contains path separators"},
		{"SlashInLock", validDir, "doc", "sub/lock", "contains path separators"},
		{"BackslashInLock", validDir, "doc", "sub\\lock", "contains path separators"},
		{"NullInDoc", validDir, "doc\x00bad", "lock", "contains null characters"},
		{"NullInLock", validDir, "doc", "lock\x00bad", "contains null characters"},
		{"SameNames", validDir, "shared.txt", "shared.txt", "must be distinct"},
		{"EscapeDoc", validDir, "../escape", "lock", "contains path separators"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := New(tc.dir, tc.doc, tc.lock)
			if err == nil {
				t.Fatalf("expected error for %s, got nil", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("expected error containing %q, got: %v", tc.wantErr, err)
			}
		})
	}

	_, err := New(validDir, "valid.json", ".valid.lock")
	if err != nil {
		t.Fatalf("expected success for valid names, got: %v", err)
	}
}

func TestReadOnlyMissingPathDoesNotCreate(t *testing.T) {
	parent := t.TempDir()
	nonexistentDir := filepath.Join(parent, "missing_subdir")
	f, err := New(nonexistentDir, "missing.json", ".missing.lock")
	if err != nil {
		t.Fatal(err)
	}

	// Read on nonexistent file in nonexistent directory
	_, err = f.Read(context.Background(), 1024)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected os.ErrNotExist, got: %v", err)
	}

	// Verify the directory was NOT created
	if _, err := os.Stat(nonexistentDir); !os.IsNotExist(err) {
		t.Fatal("read-only operation created nonexistent directory")
	}

	// Now create directory with 0700, but do NOT create document file
	if err := os.Mkdir(nonexistentDir, 0700); err != nil {
		t.Fatal(err)
	}

	_, err = f.Read(context.Background(), 1024)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected os.ErrNotExist, got: %v", err)
	}

	// Verify no lock file and no document file were created
	if _, err := os.Stat(filepath.Join(nonexistentDir, ".missing.lock")); !os.IsNotExist(err) {
		t.Fatal("read-only operation created lock file on missing document")
	}
	if _, err := os.Stat(filepath.Join(nonexistentDir, "missing.json")); !os.IsNotExist(err) {
		t.Fatal("read-only operation created document file on missing document")
	}
}

func TestFailedCallbackLeavesPreviousBytes(t *testing.T) {
	dir := privateTestDir(t)
	f, err := New(dir, "state.txt", ".state.lock")
	if err != nil {
		t.Fatal(err)
	}

	initialBytes := []byte("pristine-state-must-remain")
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return initialBytes, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// ReadModifyWrite with failing callback
	expectedErr := errors.New("simulated business logic failure")
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		if !bytes.Equal(existing, initialBytes) {
			return nil, fmt.Errorf("unexpected existing bytes: %q", string(existing))
		}
		return []byte("corrupted"), expectedErr
	})
	if !errors.Is(err, expectedErr) {
		t.Fatalf("expected error %v, got: %v", expectedErr, err)
	}

	// Verify file on disk is completely unchanged
	docPath := filepath.Join(dir, "state.txt")
	current, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(current, initialBytes) {
		t.Fatalf("file content was altered: got %q, want %q", string(current), string(initialBytes))
	}

	// ReadModifyWrite with nil return (success without write)
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		if !bytes.Equal(existing, initialBytes) {
			return nil, fmt.Errorf("unexpected existing bytes: %q", string(existing))
		}
		return nil, nil // success, no write
	})
	if err != nil {
		t.Fatalf("nil write callback returned error: %v", err)
	}
	current, err = os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(current, initialBytes) {
		t.Fatalf("file content was altered by nil write: got %q, want %q", string(current), string(initialBytes))
	}

	// Verify no leftover temporary files in dir
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), "tmp") {
			t.Fatalf("temporary file leaked: %s", entry.Name())
		}
	}
}

func TestLockCancellation(t *testing.T) {
	dir := privateTestDir(t)
	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	held := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})

	go func() {
		defer close(done)
		err := f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
			close(held)
			<-release
			return nil, nil
		})
		if err != nil {
			panic(err)
		}
	}()

	<-held

	// Attempt acquisition with short timeout context
	ctxTimeout, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	err = f.ReadModifyWrite(ctxTimeout, 1024, func(existing []byte) ([]byte, error) {
		return nil, nil
	})
	if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		t.Fatalf("expected deadline/canceled error, got: %v", err)
	}

	// Release held lock
	close(release)
	<-done

	// Subsequent ReadModifyWrite must succeed immediately
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return []byte("after-cancel"), nil
	})
	if err != nil {
		t.Fatalf("subsequent ReadModifyWrite failed: %v", err)
	}

	data, err := f.Read(context.Background(), 1024)
	if err != nil || string(data) != "after-cancel" {
		t.Fatalf("read after cancel failed: data=%q, err=%v", string(data), err)
	}
}

func TestLockAlreadyCanceledContext(t *testing.T) {
	dir := privateTestDir(t)
	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err = f.ReadModifyWrite(ctx, 1024, func(existing []byte) ([]byte, error) {
		return nil, nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got: %v", err)
	}
}

func TestMakeUnlockFnIdempotence(t *testing.T) {
	dir := privateTestDir(t)
	lockPath := filepath.Join(dir, ".test.lock")
	unlock, err := acquireLock(context.Background(), lockPath)
	if err != nil {
		t.Fatalf("acquireLock failed: %v", err)
	}

	var wg sync.WaitGroup
	errs := make([]error, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			errs[idx] = unlock()
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("unlock call %d returned error: %v", i, err)
		}
	}
}

func TestReadExceedsLimit(t *testing.T) {
	dir := privateTestDir(t)
	f, err := New(dir, "doc.txt", ".doc.lock")
	if err != nil {
		t.Fatal(err)
	}

	content := bytes.Repeat([]byte("A"), 500)
	err = f.ReadModifyWrite(context.Background(), 1000, func(existing []byte) ([]byte, error) {
		return content, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// Reading with maxBytes=100 must fail
	_, err = f.Read(context.Background(), 100)
	if err == nil {
		t.Fatal("expected error reading file exceeding limit, got nil")
	}
	if !strings.Contains(err.Error(), "exceeds size limit") {
		t.Fatalf("expected 'exceeds size limit' error, got: %v", err)
	}

	// Reading with maxBytes=1000 must succeed
	data, err := f.Read(context.Background(), 1000)
	if err != nil {
		t.Fatalf("read with sufficient limit failed: %v", err)
	}
	if len(data) != 500 {
		t.Fatalf("read length mismatch: got %d, want 500", len(data))
	}

	// Writing payload exceeding limit must fail and preserve content
	err = f.ReadModifyWrite(context.Background(), 100, func(existing []byte) ([]byte, error) {
		return bytes.Repeat([]byte("B"), 200), nil
	})
	if err == nil {
		t.Fatal("expected write exceeding limit to fail, got nil")
	}
	if !strings.Contains(err.Error(), "exceeds size limit") {
		t.Fatalf("expected write limit error, got: %v", err)
	}

	// Max bound that overflows max+1 must be rejected
	_, err = f.Read(context.Background(), math.MaxInt64)
	if err == nil {
		t.Fatal("expected Read with math.MaxInt64 to fail, got nil")
	}
	if !strings.Contains(err.Error(), "overflows max+1") {
		t.Fatalf("expected overflow error on Read, got: %v", err)
	}

	err = f.ReadModifyWrite(context.Background(), math.MaxInt64, func(existing []byte) ([]byte, error) {
		return []byte("overflow"), nil
	})
	if err == nil {
		t.Fatal("expected ReadModifyWrite with math.MaxInt64 to fail, got nil")
	}
	if !strings.Contains(err.Error(), "overflows max+1") {
		t.Fatalf("expected overflow error on ReadModifyWrite, got: %v", err)
	}
}

func TestCancellationBeforeCallbackAndPublication(t *testing.T) {
	dir := privateTestDir(t)
	f, err := New(dir, "cancel_test.txt", ".cancel_test.lock")
	if err != nil {
		t.Fatal(err)
	}

	initialData := []byte("keep-me-intact")
	err = f.ReadModifyWrite(context.Background(), 1024, func(existing []byte) ([]byte, error) {
		return initialData, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	// 1. Cancel before publication: context canceled inside callback before returning bytes
	ctxPub, cancelPub := context.WithCancel(context.Background())
	err = f.ReadModifyWrite(ctxPub, 1024, func(existing []byte) ([]byte, error) {
		cancelPub() // cancel context before publication
		return []byte("corrupted-mutation"), nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled before publication, got: %v", err)
	}

	// Verify original file untouched
	docPath := filepath.Join(dir, "cancel_test.txt")
	data, err := os.ReadFile(docPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, initialData) {
		t.Fatalf("file was modified despite publication cancel: got %q, want %q", string(data), string(initialData))
	}
}

func TestPublishedSyncErrorType(t *testing.T) {
	rootErr := errors.New("io error on sync")
	syncErr := &PublishedSyncError{Err: rootErr}

	if !errors.Is(syncErr, ErrPublishedSyncFailed) {
		t.Fatal("expected errors.Is(syncErr, ErrPublishedSyncFailed) to be true")
	}
	if !errors.Is(syncErr, rootErr) {
		t.Fatal("expected errors.Is(syncErr, rootErr) to be true")
	}
	if !strings.Contains(syncErr.Error(), "io error on sync") {
		t.Fatalf("unexpected Error string: %s", syncErr.Error())
	}
}
