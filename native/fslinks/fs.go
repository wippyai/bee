// SPDX-License-Identifier: MIT

package fslinks

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	fsapi "github.com/wippyai/runtime/api/fs"
	"github.com/wippyai/runtime/service/fs/directory"
)

type Link struct {
	Path  string `json:"path" yaml:"path"`
	Write bool   `json:"write" yaml:"write"`
}

type selectedFile struct {
	volume *directory.FS
	path   string
	write  bool
}

type FS struct {
	base  *directory.FS
	files map[string]selectedFile
}

func selectedPath(name string) bool {
	return name != "." && fs.ValidPath(name) && !strings.ContainsAny(name, "\\\x00") && len(name) <= 4096
}

func pinFile(path string, writable bool) (selectedFile, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return selectedFile{}, err
	}
	parent, name := filepath.Dir(resolved), filepath.Base(resolved)
	if err != nil {
		parent, name = filepath.Dir(path), filepath.Base(path)
		for {
			physical, parentError := filepath.EvalSymlinks(parent)
			if parentError == nil {
				parent = physical
				break
			}
			if !errors.Is(parentError, fs.ErrNotExist) {
				return selectedFile{}, parentError
			}
			next := filepath.Dir(parent)
			if next == parent {
				return selectedFile{}, parentError
			}
			name, parent = filepath.Join(filepath.Base(parent), name), next
		}
	} else {
		info, statError := os.Stat(resolved)
		if statError != nil {
			return selectedFile{}, statError
		}
		if !info.Mode().IsRegular() {
			return selectedFile{}, fs.ErrPermission
		}
	}
	mode := fs.FileMode(0400)
	if writable {
		mode |= 0200
	}
	volume, err := directory.NewFS(parent, mode, false)
	if err != nil {
		return selectedFile{}, err
	}
	return selectedFile{volume: volume, path: filepath.ToSlash(name), write: writable}, nil
}

func New(root string, links []Link) (_ *FS, err error) {
	if !filepath.IsAbs(root) || len(links) > 64 {
		return nil, fs.ErrInvalid
	}
	base, err := directory.NewFS(root, 0500, false)
	if err != nil {
		return nil, err
	}
	volume := &FS{base: base, files: make(map[string]selectedFile)}
	defer func() {
		if err != nil {
			volume.Close()
		}
	}()
	for _, link := range links {
		if !selectedPath(link.Path) {
			return nil, fs.ErrInvalid
		}
		if _, exists := volume.files[link.Path]; exists {
			return nil, fs.ErrInvalid
		}
		file, pinError := pinFile(filepath.Join(root, filepath.FromSlash(link.Path)), link.Write)
		if pinError != nil {
			return nil, pinError
		}
		volume.files[link.Path] = file
	}
	return volume, nil
}

func sourceError(err error) error {
	if err == nil || errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return fmt.Errorf("%w: %v", fs.ErrPermission, err)
}

func (volume *FS) target(name string) (*directory.FS, string, bool, error) {
	path := strings.TrimPrefix(name, "/")
	if !fs.ValidPath(path) || strings.ContainsAny(path, "\\\x00") {
		return nil, "", false, fs.ErrInvalid
	}
	if selected, exists := volume.files[path]; exists {
		return selected.volume, selected.path, selected.write, nil
	}
	return volume.base, path, false, nil
}

func (volume *FS) Open(name string) (fs.File, error) {
	return volume.OpenFile(name, os.O_RDONLY, 0)
}

func (volume *FS) OpenFile(name string, flag int, mode fs.FileMode) (fsapi.File, error) {
	selected, path, writable, err := volume.target(name)
	if err != nil {
		return nil, err
	}
	if flag != os.O_RDONLY && !writable {
		return nil, fs.ErrPermission
	}
	file, err := selected.OpenFileNoFollow(path, flag, mode)
	if err != nil {
		return nil, sourceError(err)
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		file.Close()
		return nil, fs.ErrPermission
	}
	return file, nil
}

func (volume *FS) Stat(name string) (fs.FileInfo, error) {
	selected, path, _, err := volume.target(name)
	if err != nil {
		return nil, err
	}
	info, err := selected.Lstat(path)
	if err != nil {
		return nil, sourceError(err)
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		return nil, fs.ErrPermission
	}
	return info, nil
}

func (volume *FS) Lstat(name string) (fs.FileInfo, error) { return volume.Stat(name) }

func (volume *FS) ReadDir(name string) ([]fs.DirEntry, error)        { return nil, fs.ErrPermission }
func (volume *FS) Remove(name string) error                          { return fs.ErrPermission }
func (volume *FS) Mkdir(name string, mode fs.FileMode) error         { return fs.ErrPermission }
func (volume *FS) Rename(old, new string) error                      { return fs.ErrPermission }
func (volume *FS) Truncate(name string, size int64) error            { return fs.ErrPermission }
func (volume *FS) Chtimes(name string, atime, mtime time.Time) error { return fs.ErrPermission }

func (volume *FS) WriteFileAtomic(name string, data []byte, mode fs.FileMode) error {
	selected, path, writable, err := volume.target(name)
	if err != nil {
		return err
	}
	if !writable {
		return fs.ErrPermission
	}
	return sourceError(selected.WriteFileAtomic(path, data, mode))
}

func (volume *FS) Close() error {
	err := volume.base.Close()
	for _, file := range volume.files {
		err = errors.Join(err, file.volume.Close())
	}
	return err
}
