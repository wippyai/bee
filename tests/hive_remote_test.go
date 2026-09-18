// SPDX-License-Identifier: MIT
package main

import (
	"archive/tar"
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Test 1: safeBuffer truncation & writer contract
func TestSafeBufferWriterContract(t *testing.T) {
	buf := newSafeBuffer(32)

	n, err := buf.Write([]byte{})
	if err != nil || n != 0 {
		t.Fatalf("expected (0, nil), got (%d, %v)", n, err)
	}

	chunk1 := []byte("1234567890")
	n, err = buf.Write(chunk1)
	if err != nil || n != len(chunk1) {
		t.Fatalf("expected (%d, nil), got (%d, %v)", len(chunk1), n, err)
	}
	if buf.Len() != 10 || buf.Truncated() {
		t.Fatalf("expected len 10, not truncated; got len %d, trunc %v", buf.Len(), buf.Truncated())
	}

	chunk2 := []byte("abcdefghijklmno")
	n, err = buf.Write(chunk2)
	if err != nil || n != len(chunk2) {
		t.Fatalf("expected (%d, nil), got (%d, %v)", len(chunk2), n, err)
	}
	if buf.Len() != 25 || buf.Truncated() {
		t.Fatalf("expected len 25, not truncated; got len %d, trunc %v", buf.Len(), buf.Truncated())
	}

	chunk3 := []byte("PQRSTUVWXYZ")
	n, err = buf.Write(chunk3)
	if err != nil || n != len(chunk3) {
		t.Fatalf("writer contract violated: expected (%d, nil), got (%d, %v)", len(chunk3), n, err)
	}
	if buf.Len() != 32 || !buf.Truncated() {
		t.Fatalf("expected len 32, truncated=true; got len %d, trunc %v", buf.Len(), buf.Truncated())
	}
	expectedTail := "567890abcdefghijklmnoPQRSTUVWXYZ"
	if string(buf.buf) != expectedTail {
		t.Fatalf("expected tail %q, got %q", expectedTail, string(buf.buf))
	}
	if !strings.Contains(buf.String(), expectedTail) || !strings.Contains(buf.String(), "[... resident log truncated ...]") {
		t.Fatalf("String() missing truncation marker or content: %q", buf.String())
	}

	bigBuf := newSafeBuffer(16)
	huge := []byte("0123456789abcdefghijklmnopqrstuvwxyz")
	n, err = bigBuf.Write(huge)
	if err != nil || n != len(huge) {
		t.Fatalf("writer contract violated for huge write: expected (%d, nil), got (%d, %v)", len(huge), n, err)
	}
	if bigBuf.Len() != 16 || !bigBuf.Truncated() {
		t.Fatalf("expected len 16, truncated=true; got len %d, trunc %v", bigBuf.Len(), bigBuf.Truncated())
	}
	expectedHugeTail := string(huge[len(huge)-16:])
	if string(bigBuf.buf) != expectedHugeTail {
		t.Fatalf("expected %q, got %q", expectedHugeTail, string(bigBuf.buf))
	}

	copyBuf := newSafeBuffer(64)
	srcData := bytes.Repeat([]byte("test data line\n"), 1000)
	copied, copyErr := io.Copy(copyBuf, bytes.NewReader(srcData))
	if copyErr != nil {
		t.Fatalf("io.Copy failed (possible short write violation): %v", copyErr)
	}
	if copied != int64(len(srcData)) {
		t.Fatalf("expected %d copied, got %d", len(srcData), copied)
	}
	if copyBuf.Len() != 64 || !copyBuf.Truncated() {
		t.Fatalf("expected bounded resident bytes 64, got %d", copyBuf.Len())
	}
}

// Test 2: shellQuote literal roundtrip
func TestShellQuoteRoundtrip(t *testing.T) {
	testCases := []struct {
		name  string
		input string
	}{
		{"empty", ""},
		{"simple", "hello_world"},
		{"spaces", "hello world foo bar"},
		{"single_apostrophe", "hello'world"},
		{"multiple_apostrophes", "'''foo''''bar'''"},
		{"dollar_vars", "$HOME ${USER} $$ $?"},
		{"backticks", "`date` and `whoami` and `rm -rf /`"},
		{"command_substitution", "$(echo pwned) $(cat /etc/passwd)"},
		{"newlines", "line1\nline2\nline3\n"},
		{"escapes_and_specials", "\\ \" * ? [ ] ( ) < > & | ; # ~ ="},
		{"complex_mix", "test'ing $VARS `cmd` and \n\"quoted\" ; exit 1"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			quoted := shellQuote(tc.input)
			cmd := exec.Command("sh", "-c", "printf '%s' "+quoted)
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("sh execution failed for %q (quoted: %q): %v", tc.input, quoted, err)
			}
			if string(out) != tc.input {
				t.Fatalf("roundtrip mismatch:\nexpected: %q\ngot:      %q\nquoted:   %q", tc.input, string(out), quoted)
			}
		})
	}
}

// Test 3: archiveDir trailer and nonregular refusal
type failOnTrailerWriter struct {
	writesBeforeFail int
	writeCount       int
}

func (w *failOnTrailerWriter) Write(p []byte) (int, error) {
	w.writeCount++
	if w.writeCount >= w.writesBeforeFail {
		return 0, errors.New("simulated disk full during archive trailer")
	}
	return len(p), nil
}

func TestArchiveDirTrailerAndNonregularRefusal(t *testing.T) {
	tempDir := t.TempDir()

	subDir := filepath.Join(tempDir, "subdir")
	if err := os.Mkdir(subDir, 0700); err != nil {
		t.Fatal(err)
	}
	file1 := filepath.Join(tempDir, "file1.txt")
	if err := os.WriteFile(file1, []byte("content 1"), 0600); err != nil {
		t.Fatal(err)
	}
	file2 := filepath.Join(subDir, "file2.txt")
	if err := os.WriteFile(file2, []byte("content 2"), 0600); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	if err := archiveDir(tempDir, &buf); err != nil {
		t.Fatalf("archiveDir failed on valid dir: %v", err)
	}

	tr := tar.NewReader(&buf)
	foundFiles := make(map[string]bool)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar read error: %v", err)
		}
		foundFiles[hdr.Name] = true
	}
	if !foundFiles["file1.txt"] || !foundFiles["subdir"] || !foundFiles["subdir/file2.txt"] {
		t.Fatalf("missing expected entries in archive: %v", foundFiles)
	}

	symlinkDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(symlinkDir, "real.txt"), []byte("data"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("real.txt", filepath.Join(symlinkDir, "link.txt")); err != nil {
		t.Fatal(err)
	}

	err := archiveDir(symlinkDir, io.Discard)
	if err == nil {
		t.Fatal("expected archiveDir to fail on symlink, but returned nil")
	}
	if !strings.Contains(err.Error(), "refusing non-regular file") {
		t.Fatalf("expected error mentioning 'refusing non-regular file', got: %v", err)
	}

	failWriter := &failOnTrailerWriter{writesBeforeFail: 3}
	err = archiveDir(tempDir, failWriter)
	if err == nil {
		t.Fatal("expected archiveDir to propagate trailer close error, got nil")
	}
	if !strings.Contains(err.Error(), "close tar writer") && !strings.Contains(err.Error(), "simulated disk full") {
		t.Fatalf("expected tar writer close error, got: %v", err)
	}
}

// Test 4: Input validation before SSH
func TestValidateConfig(t *testing.T) {
	validBin := ".wippy/bin/bee-wippy-hive"
	if _, err := os.Stat(validBin); err != nil {
		validBin = "/bin/sh"
	}

	t.Run("valid loopback defaults", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath: validBin,
		}
		if err := validateConfig(cfg); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if cfg.hostAddress != "127.0.0.1" || cfg.clientAddress != "127.0.0.1" {
			t.Fatalf("expected 127.0.0.1 defaults, got host=%q client=%q", cfg.hostAddress, cfg.clientAddress)
		}
	})

	t.Run("valid loopback presenter-stall", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:    validBin,
			presenterStall: true,
		}
		if err := validateConfig(cfg); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("valid loopback desktop", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:  validBin,
			desktopProbe: true,
		}
		if err := validateConfig(cfg); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	t.Run("presenter-stall combined with stall rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:    validBin,
			stallProbe:     true,
			presenterStall: true,
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "cannot be combined") {
			t.Fatalf("expected combination rejection, got: %v", err)
		}
	})

	t.Run("desktop combined with stall rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:  validBin,
			stallProbe:   true,
			desktopProbe: true,
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "cannot be combined") {
			t.Fatalf("expected combination rejection, got: %v", err)
		}
	})

	t.Run("desktop combined with presenter-stall rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:    validBin,
			presenterStall: true,
			desktopProbe:   true,
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "cannot be combined") {
			t.Fatalf("expected combination rejection, got: %v", err)
		}
	})

	t.Run("presenter-stall with ssh rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "user@10.0.0.1",
			remoteRuntimePath: "/remote/wippy",
			hostAddress:       "10.0.0.1",
			clientAddress:     "10.0.0.2",
			presenterStall:    true,
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "locally launched runtimes") {
			t.Fatalf("expected ssh rejection for presenter-stall, got: %v", err)
		}
	})

	t.Run("invalid loopback IP", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath: validBin,
			hostAddress: "invalid-ip",
		}
		if err := validateConfig(cfg); err == nil {
			t.Fatal("expected error for invalid IP")
		}
	})

	t.Run("ssh target leading dash rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "-oProxyCommand=bad",
			remoteRuntimePath: "/remote/wippy",
			hostAddress:       "10.0.0.1",
			clientAddress:     "10.0.0.2",
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "cannot begin with '-'") {
			t.Fatalf("expected leading dash rejection, got: %v", err)
		}
	})

	t.Run("ssh target invalid characters rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "user@host;rm -rf",
			remoteRuntimePath: "/remote/wippy",
			hostAddress:       "10.0.0.1",
			clientAddress:     "10.0.0.2",
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "invalid characters") {
			t.Fatalf("expected invalid characters rejection, got: %v", err)
		}
	})

	t.Run("ssh missing remote-runtime rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:   validBin,
			sshTarget:     "user@host",
			hostAddress:   "10.0.0.1",
			clientAddress: "10.0.0.2",
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "-remote-runtime is required") {
			t.Fatalf("expected missing remote runtime rejection, got: %v", err)
		}
	})

	t.Run("ssh relative remote-runtime rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "user@host",
			remoteRuntimePath: "relative/path/wippy",
			hostAddress:       "10.0.0.1",
			clientAddress:     "10.0.0.2",
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "must be an absolute path") {
			t.Fatalf("expected relative remote runtime rejection, got: %v", err)
		}
	})

	t.Run("ssh missing host-address rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "user@host",
			remoteRuntimePath: "/remote/wippy",
			clientAddress:     "10.0.0.2",
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "-host-address is required") {
			t.Fatalf("expected missing host address rejection, got: %v", err)
		}
	})

	t.Run("ssh missing client-address rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "user@host",
			remoteRuntimePath: "/remote/wippy",
			hostAddress:       "10.0.0.1",
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "-client-address is required") {
			t.Fatalf("expected missing client address rejection, got: %v", err)
		}
	})

	t.Run("ssh valid config derives remoteStageParent", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "user@10.0.0.1",
			remoteRuntimePath: "/custom/stage/wippy",
			hostAddress:       "10.0.0.1",
			clientAddress:     "10.0.0.2",
		}
		if err := validateConfig(cfg); err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if cfg.remoteStageParent != "/custom/stage" {
			t.Fatalf("expected derived remoteStageParent /custom/stage, got: %q", cfg.remoteStageParent)
		}
	})

	t.Run("ssh explicit relative remoteStageParent rejected", func(t *testing.T) {
		cfg := &harnessConfig{
			runtimePath:       validBin,
			sshTarget:         "user@10.0.0.1",
			remoteRuntimePath: "/custom/stage/wippy",
			remoteStageParent: "relative/dir",
			hostAddress:       "10.0.0.1",
			clientAddress:     "10.0.0.2",
		}
		if err := validateConfig(cfg); err == nil || !strings.Contains(err.Error(), "must be an absolute directory") {
			t.Fatalf("expected relative remote stage parent rejection, got: %v", err)
		}
	})
}
