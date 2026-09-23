// SPDX-License-Identifier: MIT

// Package privatefile provides protected, atomic, locked local filesystem storage
// for private machine credentials and configuration files.
//
// Authority and Boundaries:
// Storage relies on native OS-user filesystem authority (owner-only permissions)
// to protect local private files. It makes no false sandbox claims: any process
// running as the same OS user has equal access to these files (same account is not sandboxed).
package privatefile

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
)

var (
	// ErrInvalidName is returned when a document or lock name is invalid or escapes the directory.
	ErrInvalidName = errors.New("privatefile: invalid name")

	// ErrPublishedSyncFailed indicates that a file was atomically published but syncing its directory failed.
	ErrPublishedSyncFailed = errors.New("privatefile: directory sync failed after publish")
)

// PublishedSyncError records a directory sync failure after a file was published to disk.
// This indicates uncertainty: the file contents were successfully published, but
// directory metadata sync failed.
type PublishedSyncError struct {
	Err error
}

func (e *PublishedSyncError) Error() string {
	return fmt.Sprintf("file published but directory sync failed: %v", e.Err)
}

func (e *PublishedSyncError) Unwrap() error {
	return e.Err
}

func (e *PublishedSyncError) Is(target error) bool {
	return target == ErrPublishedSyncFailed
}

// DefaultMaxBytes is the default bound for file reads when no positive limit is supplied.
const DefaultMaxBytes = 64 * 1024

// File represents a single protected private document and its companion lock file
// under a validated private directory. It is an immutable path descriptor holding no
// long-lived descriptors or locks; operations acquire and release resources internally.
type File struct {
	dir      string
	docName  string
	docPath  string
	lockName string
	lockPath string
}

// New validates names and returns an immutable File targeting docName and lockName in dir.
// The document and lock names must each be a single basename and cannot be identical.
// Directory escaping and Windows ADS / reserved names are rejected where platform appropriate.
// Neither the directory nor any files are created by New.
func New(dir, docName, lockName string) (*File, error) {
	if strings.TrimSpace(dir) == "" {
		return nil, errors.New("privatefile: directory path is required")
	}
	if err := validateBasename(docName); err != nil {
		return nil, fmt.Errorf("document name: %w", err)
	}
	if err := validateBasename(lockName); err != nil {
		return nil, fmt.Errorf("lock name: %w", err)
	}
	if sameFilename(docName, lockName) {
		return nil, fmt.Errorf("%w: document and lock names must be distinct", ErrInvalidName)
	}

	cleanDir := filepath.Clean(dir)
	docPath := filepath.Join(cleanDir, docName)
	lockPath := filepath.Join(cleanDir, lockName)

	if filepath.Dir(docPath) != cleanDir || filepath.Dir(lockPath) != cleanDir {
		return nil, fmt.Errorf("%w: path escapes directory", ErrInvalidName)
	}

	return &File{
		dir:      cleanDir,
		docName:  docName,
		docPath:  docPath,
		lockName: lockName,
		lockPath: lockPath,
	}, nil
}

// Read reads the document file up to maxBytes without acquiring an exclusive lock.
// If the document file does not exist, os.ErrNotExist is returned without creating
// the directory or any files.
func (f *File) Read(ctx context.Context, maxBytes int64) ([]byte, error) {
	if ctx == nil {
		return nil, errors.New("context is required")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if maxBytes == 0 {
		maxBytes = DefaultMaxBytes
	} else if maxBytes < 0 || maxBytes > math.MaxInt64-1 {
		return nil, errors.New("privatefile: max bytes limit overflows max+1")
	}

	// Read without creating on read-only missing path:
	if _, err := os.Lstat(f.docPath); err != nil {
		return nil, err
	}

	if err := checkDirPermissions(f.dir); err != nil {
		return nil, err
	}

	return readBoundedFile(f.docPath, maxBytes)
}

// ReadModifyWrite executes transform under an exclusive OS lock on the companion lock file.
//
// Invariants:
//  1. Acquires lock on the stable lock inode without unlinking.
//  2. Reads and validates bounded existing document. If the document exists, it must be a
//     regular file with owner-only permissions and not exceed maxBytes; existing insecure,
//     non-regular, or symlink documents are rejected without repair and preserve previous bytes.
//     If the document does not exist, existing is nil.
//  3. Checks context cancellation before invoking fn.
//  4. Invokes fn(existing). An error returned by fn aborts the operation and preserves existing bytes.
//  5. If fn returns (nil, nil), no write occurs (success without mutation).
//  6. If fn returns (newBytes, nil), newBytes is size-checked against maxBytes (rejecting payloads
//     larger than maxBytes and bounds that overflow max+1).
//  7. Checks context cancellation before publication.
//  8. Atomically publishes newBytes via temporary file, fsync, rename over docPath, and directory fsync.
func (f *File) ReadModifyWrite(ctx context.Context, maxBytes int64, fn func(existing []byte) ([]byte, error)) (retErr error) {
	if ctx == nil {
		return errors.New("context is required")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if fn == nil {
		return errors.New("privatefile: transform function is required")
	}
	if maxBytes == 0 {
		maxBytes = DefaultMaxBytes
	} else if maxBytes < 0 || maxBytes > math.MaxInt64-1 {
		return errors.New("privatefile: max bytes limit overflows max+1")
	}

	// Ensure private directory exists with owner-only access.
	if err := ensurePrivateDir(f.dir); err != nil {
		return fmt.Errorf("create private directory: %w", err)
	}

	// Verify directory security where platform supported (never repairs existing insecure dir).
	if err := checkDirPermissions(f.dir); err != nil {
		return err
	}

	// Acquire exclusive lock on stable lock inode.
	unlock, err := acquireLock(ctx, f.lockPath)
	if err != nil {
		return err
	}
	defer func() {
		if unlockErr := unlock(); unlockErr != nil && retErr == nil {
			retErr = unlockErr
		}
	}()

	// Check cancellation after acquiring lock.
	if err := ctx.Err(); err != nil {
		return err
	}

	// Read and validate existing document if present.
	var existing []byte
	fi, err := os.Lstat(f.docPath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		// Document does not exist: existing remains nil.
	} else {
		// Document exists: must validate strictly. Do not repair insecure/symlink/nonregular.
		if fi.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("file %q is a symlink (not a regular file)", f.docPath)
		}
		if !fi.Mode().IsRegular() {
			return fmt.Errorf("file %q is not a regular file (mode: %s)", f.docPath, fi.Mode())
		}
		if err := checkFilePermissions(fi); err != nil {
			return fmt.Errorf("insecure file %q: %w", f.docPath, err)
		}
		if err := checkFilePathPermissions(f.docPath); err != nil {
			return fmt.Errorf("file access check failed: %w", err)
		}

		data, err := readBoundedFile(f.docPath, maxBytes)
		if err != nil {
			return err
		}
		existing = data
	}

	// Check cancellation before invoking callback.
	if err := ctx.Err(); err != nil {
		return err
	}

	// Invoke user transformation.
	newBytes, err := fn(existing)
	if err != nil {
		return err // error means preserve bytes
	}
	if newBytes == nil {
		return nil // nil bytes success = no write
	}

	// Validate write size with same bound.
	if int64(len(newBytes)) > maxBytes {
		return fmt.Errorf("write payload exceeds size limit of %d bytes", maxBytes)
	}

	// Check cancellation before publication.
	if err := ctx.Err(); err != nil {
		return err
	}

	return writeAtomicFile(f.dir, f.docPath, f.docName, newBytes)
}

// EnsurePrivateDir creates dir with owner-only permissions if it does not exist.
// If dir already exists, its permissions are not repaired.
func EnsurePrivateDir(dir string) error {
	return ensurePrivateDir(dir)
}

// SetOwnerOnlyPermissions sets owner-only permissions on path (0700 for directories, 0600 for files).
func SetOwnerOnlyPermissions(path string) error {
	return setOwnerOnlyPermissions(path)
}

func validateBasename(name string) error {
	if name == "" {
		return fmt.Errorf("%w: name cannot be empty", ErrInvalidName)
	}
	if name == "." || name == ".." {
		return fmt.Errorf("%w: %q is not a valid filename", ErrInvalidName, name)
	}
	if strings.ContainsAny(name, "/\\") {
		return fmt.Errorf("%w: %q contains path separators", ErrInvalidName, name)
	}
	if filepath.Base(name) != name {
		return fmt.Errorf("%w: %q is not a single basename", ErrInvalidName, name)
	}
	if strings.ContainsRune(name, 0) {
		return fmt.Errorf("%w: %q contains null characters", ErrInvalidName, name)
	}
	return validateBasenamePlatform(name)
}

func readBoundedFile(filePath string, maxBytes int64) ([]byte, error) {
	if maxBytes == 0 {
		maxBytes = DefaultMaxBytes
	} else if maxBytes < 0 || maxBytes > math.MaxInt64-1 {
		return nil, errors.New("privatefile: max bytes limit overflows max+1")
	}

	fi, err := os.Lstat(filePath)
	if err != nil {
		return nil, err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("file %q is a symlink (not a regular file)", filePath)
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("file %q is not a regular file (mode: %s)", filePath, fi.Mode())
	}
	if err := checkFilePermissions(fi); err != nil {
		return nil, fmt.Errorf("insecure file %q: %w", filePath, err)
	}
	if err := checkFilePathPermissions(filePath); err != nil {
		return nil, fmt.Errorf("file access check failed: %w", err)
	}

	file, err := openExistingFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("read file: %w", err)
	}
	defer file.Close()

	st, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat opened file: %w", err)
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("opened file %q is not regular: %s", filePath, st.Mode())
	}
	if err := checkFilePermissions(st); err != nil {
		return nil, fmt.Errorf("insecure opened file %q: %w", filePath, err)
	}

	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read file: %w", err)
	}
	if int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("file exceeds size limit of %d bytes", maxBytes)
	}
	return data, nil
}

func writeAtomicFile(dir, docPath, docName string, data []byte) error {
	tempFile, err := os.CreateTemp(dir, "."+docName+"-tmp-*")
	if err != nil {
		return fmt.Errorf("create temporary file: %w", err)
	}
	tempPath := tempFile.Name()

	success := false
	defer func() {
		if !success {
			_ = tempFile.Close()
			_ = os.Remove(tempPath)
		}
	}()

	if err := setOwnerOnlyPermissions(tempPath); err != nil {
		return fmt.Errorf("set permissions on temporary file: %w", err)
	}

	if _, err := tempFile.Write(data); err != nil {
		return fmt.Errorf("write temporary file: %w", err)
	}

	if err := tempFile.Sync(); err != nil {
		return fmt.Errorf("fsync temporary file: %w", err)
	}

	if err := tempFile.Close(); err != nil {
		return fmt.Errorf("close temporary file: %w", err)
	}

	// Validate target path before rename if it exists
	if tfi, err := os.Lstat(docPath); err == nil {
		if tfi.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("target file %q is a symlink", docPath)
		}
		if !tfi.Mode().IsRegular() {
			return fmt.Errorf("target file %q is not a regular file (mode: %s)", docPath, tfi.Mode())
		}
		if err := checkFilePermissions(tfi); err != nil {
			return fmt.Errorf("target file %q is insecure: %w", docPath, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat target file %q: %w", docPath, err)
	}

	if err := os.Rename(tempPath, docPath); err != nil {
		return fmt.Errorf("rename temporary file: %w", err)
	}

	if err := syncDirChecked(dir); err != nil {
		return &PublishedSyncError{Err: err}
	}
	success = true
	return nil
}
