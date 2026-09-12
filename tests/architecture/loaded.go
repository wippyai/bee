// SPDX-License-Identifier: MIT
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type loadedEntry struct {
	ID   string `json:"id"`
	Meta struct {
		Type string `json:"type"`
	} `json:"meta"`
}

// CheckLoadedInventories inspects what the runtime actually loads from source
// and from dist/bee.wapp, using the same registry list --json read as the
// previous checker.
func CheckLoadedInventories(catalog *Catalog, runtime string) error {
	if err := CheckLoadedRegistry(catalog, runtime, catalog.Root, false); err != nil {
		return err
	}
	pack := filepath.Join(catalog.Root, "dist", "bee.wapp")
	directory, err := os.MkdirTemp("", "bee-pack-audit-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	if err := copyFile(pack, filepath.Join(directory, "bee.wapp")); err != nil {
		return err
	}
	lock := "directories:\n  modules: ./vendor\n  src: ./bee.wapp\nmodules: []\n"
	if err := os.WriteFile(filepath.Join(directory, "wippy.lock"), []byte(lock), 0644); err != nil {
		return err
	}
	return CheckLoadedRegistry(catalog, runtime, directory, true)
}

// CheckLoadedRegistry compares one runtime registry list against the declared graph.
func CheckLoadedRegistry(catalog *Catalog, runtime, cwd string, packed bool) error {
	loaded, err := listRegistry(runtime, cwd)
	if err != nil {
		return err
	}
	if err := CheckLoadedMatchesDeclared(catalog, loaded); err != nil {
		return err
	}
	label := "Source"
	if packed {
		label = "Pack"
	}
	fmt.Printf("%s registry: %d entries; no legacy namespaces\n", label, len(loaded))
	return nil
}

// CheckLoadedMatchesDeclared is the exact source/pack inventory comparison.
func CheckLoadedMatchesDeclared(catalog *Catalog, loaded []loadedEntry) error {
	got := map[string]struct{}{}
	for _, entry := range loaded {
		got[entry.ID] = struct{}{}
		namespace, _, ok := strings.Cut(entry.ID, ":")
		if !ok {
			return fmt.Errorf("Unexpected loaded namespace: %s", entry.ID)
		}
		if _, allowed := allowedLoadedNamespaces[namespace]; !allowed {
			return fmt.Errorf("Unexpected loaded namespace: %s", entry.ID)
		}
		if entry.Meta.Type == "test" {
			return fmt.Errorf("%s", entry.ID)
		}
	}
	declared := map[string]struct{}{}
	for id := range catalog.Entries {
		declared[id] = struct{}{}
	}
	if !equalSet(got, setKeys(declared)...) {
		return fmt.Errorf("Loaded entries differ from the declared core")
	}
	return nil
}

func listRegistry(runtime, cwd string) ([]loadedEntry, error) {
	cmd := exec.Command(runtime, "registry", "list", "--json")
	cmd.Dir = cwd
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("registry list --json: %w\n%s", err, stderr.String())
	}
	var loaded []loadedEntry
	if err := json.Unmarshal(out, &loaded); err != nil {
		return nil, fmt.Errorf("registry list --json: %w", err)
	}
	return loaded, nil
}

func copyFile(src, dest string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}
