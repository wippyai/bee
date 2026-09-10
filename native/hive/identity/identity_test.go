// SPDX-License-Identifier: MIT

package identity

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/wippyai/bee/native/internal/privatefile"
)

// TestSubprocessHelper is invoked as a subprocess entry point by TestSubprocessConcurrentCreate.
func TestSubprocessHelper(t *testing.T) {
	if os.Getenv("TEST_SUBPROCESS_CONCURRENT") != "1" {
		return
	}
	dir := os.Getenv("TEST_SUBPROCESS_IDENTITY_DIR")
	if dir == "" {
		fmt.Fprintln(os.Stderr, "missing TEST_SUBPROCESS_IDENTITY_DIR")
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	ident, err := OpenOrCreate(ctx, dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "OpenOrCreate error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("MID:%s:PUB:%s\n", ident.ID(), hex.EncodeToString(ident.PublicKey()))
	os.Exit(0)
}

// 1. True subprocess concurrent create test: multiple OS subprocesses attempt
// OpenOrCreate concurrently. All must succeed and obtain the exact same machine identity.
func privateTestDirectory(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "identity")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := privatefile.SetOwnerOnlyPermissions(dir); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestSubprocessConcurrentCreate(t *testing.T) {
	dir := privateTestDirectory(t)

	const workers = 8
	var wg sync.WaitGroup
	results := make([]string, workers)
	errs := make([]error, workers)

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()

			cmd := exec.Command(os.Args[0], "-test.run=^TestSubprocessHelper$")
			cmd.Env = append(os.Environ(),
				"TEST_SUBPROCESS_CONCURRENT=1",
				"TEST_SUBPROCESS_IDENTITY_DIR="+dir,
			)

			out, err := cmd.CombinedOutput()
			if err != nil {
				errs[idx] = fmt.Errorf("worker %d failed: %w (output: %s)", idx, err, string(out))
				return
			}

			// Extract the MID:... line from stdout
			lines := strings.Split(string(out), "\n")
			for _, l := range lines {
				l = strings.TrimSpace(l)
				if strings.HasPrefix(l, "MID:") {
					results[idx] = l
					break
				}
			}
			if results[idx] == "" {
				errs[idx] = fmt.Errorf("worker %d produced no identity output: %s", idx, string(out))
			}
		}(i)
	}

	wg.Wait()

	for i, err := range errs {
		if err != nil {
			t.Fatalf("worker %d reported error: %v", i, err)
		}
	}

	expected := results[0]
	if expected == "" {
		t.Fatal("empty identity result from worker 0")
	}

	for i := 1; i < workers; i++ {
		if results[i] != expected {
			t.Fatalf("worker %d got different identity %q than worker 0 %q", i, results[i], expected)
		}
	}

	// Verify the persisted identity file on disk
	fi, err := os.Stat(filepath.Join(dir, IdentityFileName))
	if err != nil {
		t.Fatalf("stat identity file: %v", err)
	}
	if !fi.Mode().IsRegular() {
		t.Fatalf("identity file is not regular: %s", fi.Mode())
	}
	if runtime.GOOS != "windows" && fi.Mode().Perm() != 0600 {
		t.Fatalf("identity file has unexpected permissions: %04o (expected 0600)", fi.Mode().Perm())
	}

	// Cold verify in parent process
	ident, err := OpenOrCreate(context.Background(), dir)
	if err != nil {
		t.Fatalf("parent OpenOrCreate failed: %v", err)
	}
	expectedParent := fmt.Sprintf("MID:%s:PUB:%s", ident.ID(), hex.EncodeToString(ident.PublicKey()))
	if expectedParent != expected {
		t.Fatalf("parent identity %s does not match workers %s", expectedParent, expected)
	}
}

// 2. Cold reopen and sign verification: verify cold reopen returns the same identity
// and that Sign produces deterministic Ed25519 signatures verifiable with the public key.
func TestColdReopenAndSignVerification(t *testing.T) {
	dir := privateTestDirectory(t)

	ctx := context.Background()
	id1, err := OpenOrCreate(ctx, dir)
	if err != nil {
		t.Fatalf("first OpenOrCreate failed: %v", err)
	}

	if !strings.HasPrefix(id1.ID(), "mid_") {
		t.Fatalf("expected machine ID to start with mid_, got %q", id1.ID())
	}

	pub1 := id1.PublicKey()
	if len(pub1) != ed25519.PublicKeySize {
		t.Fatalf("unexpected public key length: %d", len(pub1))
	}

	// Test signature verification
	msg := []byte("bee machine identity test payload 12345")
	sig1 := id1.Sign(msg)
	if !ed25519.Verify(pub1, msg, sig1) {
		t.Fatal("signature verification failed with identity's public key")
	}

	// Test public key immutability: mutating returned slice does not corrupt internal key
	pub1[0] ^= 0xff
	if bytes.Equal(pub1, id1.PublicKey()) {
		t.Fatal("PublicKey() did not return an isolated copy; mutation affected internal state")
	}

	// Cold reopen
	id2, err := OpenOrCreate(ctx, dir)
	if err != nil {
		t.Fatalf("second OpenOrCreate failed: %v", err)
	}

	if id2.ID() != id1.ID() {
		t.Fatalf("machine ID mismatch: %s != %s", id2.ID(), id1.ID())
	}

	if !bytes.Equal(id2.PublicKey(), id1.PublicKey()) {
		t.Fatal("public keys mismatch after reopen")
	}

	sig2 := id2.Sign(msg)
	if !bytes.Equal(sig1, sig2) {
		t.Fatal("Ed25519 signature differed across reopens for identical message")
	}

	if !ed25519.Verify(id2.PublicKey(), msg, sig2) {
		t.Fatal("signature verification failed on cold reopen identity")
	}
}

// 3. Malformed, unsupported version, and insecure permission refusal without changing file.
func TestRefusalWithoutChangingFile(t *testing.T) {
	ctx := context.Background()

	t.Run("MalformedJSON", func(t *testing.T) {
		dir := privateTestDirectory(t)
		filePath := filepath.Join(dir, IdentityFileName)
		corruptContent := []byte(`{ "version": 1, "corrupt_json": true, incomplete...`)
		if err := os.WriteFile(filePath, corruptContent, 0600); err != nil {
			t.Fatal(err)
		}

		_, err := OpenOrCreate(ctx, dir)
		if err == nil {
			t.Fatal("expected OpenOrCreate to fail on malformed JSON, got nil")
		}

		// File must NOT be modified or replaced
		content, err := os.ReadFile(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(content, corruptContent) {
			t.Fatal("identity file was altered or regenerated after malformed JSON failure")
		}
	})

	t.Run("UnsupportedVersion", func(t *testing.T) {
		dir := privateTestDirectory(t)
		filePath := filepath.Join(dir, IdentityFileName)
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		rec := persistedIdentity{
			Version:    999, // unsupported
			KeyType:    IdentityKeyType,
			MachineID:  DeriveMachineID(pub),
			PublicKey:  hex.EncodeToString(pub),
			PrivateKey: hex.EncodeToString(priv),
		}
		data, err := json.Marshal(rec)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filePath, data, 0600); err != nil {
			t.Fatal(err)
		}

		_, err = OpenOrCreate(ctx, dir)
		if err == nil {
			t.Fatal("expected OpenOrCreate to fail on unsupported version, got nil")
		}
		if !strings.Contains(err.Error(), "unsupported identity version") {
			t.Fatalf("unexpected error message: %v", err)
		}

		content, err := os.ReadFile(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(content, data) {
			t.Fatal("identity file was altered after unsupported version refusal")
		}
	})

	t.Run("UnsupportedKeyType", func(t *testing.T) {
		dir := privateTestDirectory(t)
		filePath := filepath.Join(dir, IdentityFileName)
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		rec := persistedIdentity{
			Version:    IdentityVersion,
			KeyType:    "secp256k1", // unsupported
			MachineID:  DeriveMachineID(pub),
			PublicKey:  hex.EncodeToString(pub),
			PrivateKey: hex.EncodeToString(priv),
		}
		data, err := json.Marshal(rec)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filePath, data, 0600); err != nil {
			t.Fatal(err)
		}

		_, err = OpenOrCreate(ctx, dir)
		if err == nil {
			t.Fatal("expected OpenOrCreate to fail on unsupported key type, got nil")
		}
		if !strings.Contains(err.Error(), "unsupported identity key type") {
			t.Fatalf("unexpected error message: %v", err)
		}

		content, err := os.ReadFile(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(content, data) {
			t.Fatal("identity file was altered after unsupported key type refusal")
		}
	})

	t.Run("CorruptKeyBytes", func(t *testing.T) {
		dir := privateTestDirectory(t)
		filePath := filepath.Join(dir, IdentityFileName)
		rec := persistedIdentity{
			Version:    IdentityVersion,
			KeyType:    IdentityKeyType,
			MachineID:  "mid_1234",
			PublicKey:  "abcd",     // too short
			PrivateKey: "deadbeef", // too short
		}
		data, err := json.Marshal(rec)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filePath, data, 0600); err != nil {
			t.Fatal(err)
		}

		_, err = OpenOrCreate(ctx, dir)
		if err == nil {
			t.Fatal("expected failure on corrupt key bytes, got nil")
		}

		content, err := os.ReadFile(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(content, data) {
			t.Fatal("identity file was altered after corrupt key refusal")
		}
	})

	t.Run("MismatchedPublicAndPrivateKey", func(t *testing.T) {
		dir := privateTestDirectory(t)
		filePath := filepath.Join(dir, IdentityFileName)
		pub1, _, _ := ed25519.GenerateKey(rand.Reader)
		_, priv2, _ := ed25519.GenerateKey(rand.Reader)
		rec := persistedIdentity{
			Version:    IdentityVersion,
			KeyType:    IdentityKeyType,
			MachineID:  DeriveMachineID(pub1),
			PublicKey:  hex.EncodeToString(pub1),
			PrivateKey: hex.EncodeToString(priv2),
		}
		data, err := json.Marshal(rec)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filePath, data, 0600); err != nil {
			t.Fatal(err)
		}

		_, err = OpenOrCreate(ctx, dir)
		if err == nil {
			t.Fatal("expected failure on mismatched public/private key, got nil")
		}

		content, err := os.ReadFile(filePath)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(content, data) {
			t.Fatal("identity file was altered after mismatched key refusal")
		}
	})

	if runtime.GOOS != "windows" {
		t.Run("InsecurePermissionsRefusal", func(t *testing.T) {
			dir := privateTestDirectory(t)
			filePath := filepath.Join(dir, IdentityFileName)

			// First create valid identity
			id, err := OpenOrCreate(ctx, dir)
			if err != nil {
				t.Fatalf("setup failed: %v", err)
			}

			// Read valid content
			origContent, err := os.ReadFile(filePath)
			if err != nil {
				t.Fatal(err)
			}

			// Change file mode to insecure 0644 (world readable)
			if err := os.Chmod(filePath, 0644); err != nil {
				t.Fatal(err)
			}

			// OpenOrCreate must refuse
			_, err = OpenOrCreate(ctx, dir)
			if err == nil {
				t.Fatal("expected failure on insecure file permissions, got nil")
			}
			if !strings.Contains(err.Error(), "insecure") {
				t.Fatalf("expected insecure error, got: %v", err)
			}

			// Verify file content is unchanged
			curContent, err := os.ReadFile(filePath)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(curContent, origContent) {
				t.Fatal("identity file was altered after permission refusal")
			}

			// Verify file mode was NOT overwritten or repaired
			fi, err := os.Stat(filePath)
			if err != nil {
				t.Fatal(err)
			}
			if fi.Mode().Perm() != 0644 {
				t.Fatalf("file permissions changed unexpectedly: %04o", fi.Mode().Perm())
			}

			_ = id
		})

		t.Run("NonRegularFileSymlinkRefusal", func(t *testing.T) {
			dir := privateTestDirectory(t)
			targetFile := filepath.Join(dir, "target.txt")
			if err := os.WriteFile(targetFile, []byte("target"), 0600); err != nil {
				t.Fatal(err)
			}
			symlinkPath := filepath.Join(dir, IdentityFileName)
			if err := os.Symlink(targetFile, symlinkPath); err != nil {
				t.Fatal(err)
			}

			_, err := OpenOrCreate(ctx, dir)
			if err == nil {
				t.Fatal("expected failure on symlink identity file, got nil")
			}
			if !strings.Contains(err.Error(), "not a regular file") {
				t.Fatalf("expected 'not a regular file' error, got: %v", err)
			}

			// Verify symlink is still a symlink
			lfi, err := os.Lstat(symlinkPath)
			if err != nil {
				t.Fatal(err)
			}
			if lfi.Mode()&os.ModeSymlink == 0 {
				t.Fatal("symlink was replaced!")
			}
		})
	}
}

// 4. Canceled lock waiter: verify that waiting on a locked directory cleanly cancels
// when the context deadline/cancel fires, leaves the lock file intact, releases any handles,
// and permits subsequent acquisition once the lock is freed.
func TestCanceledLockWaiter(t *testing.T) {
	dir := privateTestDirectory(t)

	// Step 1: Hold the lock in this test
	pf, err := privatefile.New(dir, IdentityFileName, LockFileName)
	if err != nil {
		t.Fatalf("privatefile.New failed: %v", err)
	}

	held := make(chan struct{})
	release := make(chan struct{})
	done := make(chan struct{})

	go func() {
		defer close(done)
		_ = pf.ReadModifyWrite(context.Background(), 4096, func(existing []byte) ([]byte, error) {
			close(held)
			<-release
			return nil, nil
		})
	}()

	<-held

	// Step 2: Attempt OpenOrCreate with a short timeout context
	ctxCancel, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err = OpenOrCreate(ctxCancel, dir)
	duration := time.Since(start)

	if err == nil {
		t.Fatal("expected canceled OpenOrCreate to fail while lock is held, got nil")
	}
	if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context deadline/canceled error, got: %v", err)
	}
	if duration < 40*time.Millisecond {
		t.Fatalf("waiter returned too early: %v", duration)
	}

	// Step 3: Release the held lock
	close(release)
	<-done

	// Step 4: Now OpenOrCreate must immediately succeed
	ident, err := OpenOrCreate(context.Background(), dir)
	if err != nil {
		t.Fatalf("subsequent OpenOrCreate failed: %v", err)
	}
	if ident == nil || ident.ID() == "" {
		t.Fatal("expected valid identity after lock release")
	}

	// Lock file inode must remain intact (never unlinked)
	lockFi, err := os.Stat(filepath.Join(dir, LockFileName))
	if err != nil {
		t.Fatalf("stat lock file: %v", err)
	}
	if !lockFi.Mode().IsRegular() {
		t.Fatalf("lock file is not a regular file: %s", lockFi.Mode())
	}
}

// 5. No sensitive errors: ensure private key material is never printed in errors,
// String formatting, GoString formatting, fmt formatters, or JSON exports.
func TestNoSensitiveErrors(t *testing.T) {
	dir := privateTestDirectory(t)

	ident, err := OpenOrCreate(context.Background(), dir)
	if err != nil {
		t.Fatalf("OpenOrCreate failed: %v", err)
	}

	privHex := hex.EncodeToString(ident.privateKey)
	privRaw := string(ident.privateKey)

	// Check string formatters
	formatChecks := []struct {
		name string
		val  string
	}{
		{"String", ident.String()},
		{"GoString", ident.GoString()},
		{"Sprintf_v", fmt.Sprintf("%v", ident)},
		{"Sprintf_plus_v", fmt.Sprintf("%+v", ident)},
		{"Sprintf_sharp_v", fmt.Sprintf("%#v", ident)},
		{"Sprintf_s", fmt.Sprintf("%s", ident)},
		{"Sprintf_q", fmt.Sprintf("%q", ident)},
	}

	for _, fc := range formatChecks {
		if strings.Contains(fc.val, privHex) {
			t.Fatalf("formatter %s leaked hex private key: %s", fc.name, fc.val)
		}
		if strings.Contains(fc.val, privRaw) {
			t.Fatalf("formatter %s leaked raw private key: %s", fc.name, fc.val)
		}
	}

	// Check JSON marshalling of Identity struct
	jsonBytes, err := json.Marshal(ident)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(jsonBytes), privHex) {
		t.Fatalf("MarshalJSON leaked hex private key: %s", string(jsonBytes))
	}
	if strings.Contains(string(jsonBytes), "private_key") {
		t.Fatalf("MarshalJSON included private_key field: %s", string(jsonBytes))
	}

	// Check error messages: inject canary secret into corrupted file and verify
	// error messages do NOT leak the secret.
	canaryPriv := "SUPER_SECRET_PRIVATE_KEY_BYTES_CANARY_VALUE_1234567890123456789012"
	canaryHex := hex.EncodeToString([]byte(canaryPriv))

	corruptDir := privateTestDirectory(t)
	filePath := filepath.Join(corruptDir, IdentityFileName)
	badRec := persistedIdentity{
		Version:    IdentityVersion,
		KeyType:    IdentityKeyType,
		MachineID:  "mid_test",
		PublicKey:  "01020304", // invalid size
		PrivateKey: canaryHex,
	}
	badJSON, _ := json.Marshal(badRec)
	_ = os.WriteFile(filePath, badJSON, 0600)

	_, err = OpenOrCreate(context.Background(), corruptDir)
	if err == nil {
		t.Fatal("expected error on corrupt file, got nil")
	}

	errStr := err.Error()
	if strings.Contains(errStr, canaryHex) {
		t.Fatalf("error message leaked hex canary secret: %s", errStr)
	}
	if strings.Contains(errStr, canaryPriv) {
		t.Fatalf("error message leaked raw canary secret: %s", errStr)
	}
}
