// SPDX-License-Identifier: MIT
// Refresh sealed fixture packs with current Lua sources and two release identities.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/wippyai/wapp"
)

type fixturePack struct {
	Input, Output, Version, Component string
}
type codeDeclaration struct {
	Component, Kind string
	Meta            map[string]any
	Data            map[string]any
}

func main() {
	var config struct {
		Packs        []fixturePack
		Sources      map[string]string
		Identity     map[string]any
		Declarations map[string]codeDeclaration
	}
	data, err := os.ReadFile(os.Args[1])
	mustPack(err)
	mustPack(json.Unmarshal(data, &config))
	for _, pack := range config.Packs {
		body, err := os.ReadFile(pack.Input)
		mustPack(err)
		reader, err := wapp.NewReader(bytes.NewReader(body))
		mustPack(err)
		entries, err := reader.GetEntries()
		mustPack(err)
		// Native enrollment is host-owned now; old sealed seeds still contain
		// the retired package default. Current fixture packs omit that entry.
		filtered := entries[:0]
		for _, entry := range entries {
			if entry.ID.String() != "bee.hive.supervisor:enrollment_nodes" {
				filtered = append(filtered, entry)
			}
		}
		entries = filtered
		resident := map[string]bool{}
		for _, entry := range entries {
			resident[entry.ID.String()] = true
		}
		missing := []string{}
		for id, declaration := range config.Declarations {
			if declaration.Component == pack.Component && !resident[id] {
				missing = append(missing, id)
			}
		}
		sort.Strings(missing)
		for _, id := range missing {
			declaration := config.Declarations[id]
			namespace, name, found := strings.Cut(id, ":")
			if !found {
				panic("invalid source declaration identity")
			}
			entries = append(entries, wapp.Entry{ID: wapp.NewID(namespace, name), Kind: declaration.Kind, Meta: declaration.Meta, Data: declaration.Data})
		}
		for i := range entries {
			entry := &entries[i]
			fields, ok := entry.Data.(map[string]any)
			if !ok {
				continue
			}
			if declaration, found := config.Declarations[entry.ID.String()]; found {
				for _, key := range []string{"imports", "modules", "method"} {
					value, found := declaration.Data[key]
					delete(fields, key)
					if found {
						fields[key] = value
					}
				}
			}
			if source := config.Sources[entry.ID.String()]; source != "" {
				code, err := os.ReadFile(source)
				mustPack(err)
				if entry.ID.String() == "bee.settings.app:view" {
					code = bytes.ReplaceAll(code, []byte("BEE SETTINGS · ABOUT"), []byte("BEE SETTINGS · ABOUT proof marker "+pack.Version))
				}
				fields["source"] = string(code)
			}
			if entry.Kind == "ns.dependency" {
				component, _ := fields["component"].(string)
				if strings.HasPrefix(component, "bee/") {
					fields["version"] = pack.Version
				}
			}
			if entry.ID.String() == "bee.env:binary_identity" {
				for key, value := range config.Identity {
					fields[key] = value
				}
				fields["version"], fields["build"] = pack.Version, "standalone-fixture"
			}
		}
		resources := []wapp.ResourceSpec{}
		for _, resource := range reader.ListResources() {
			fsys, err := reader.GetFS(resource.ID)
			mustPack(err)
			resources = append(resources, wapp.ResourceSpec{ID: resource.ID, Meta: resource.Meta, FS: fsys})
		}
		metadata, err := reader.GetMetadata()
		mustPack(err)
		metadata["version"] = pack.Version
		var output bytes.Buffer
		mustPack(wapp.NewWriter().PackWithResources(metadata, entries, resources, &output))
		mustPack(os.MkdirAll(filepath.Dir(pack.Output), 0700))
		mustPack(os.WriteFile(pack.Output, output.Bytes(), 0600))
		sum := sha256.Sum256(output.Bytes())
		fmt.Println(pack.Output + " " + hex.EncodeToString(sum[:]))
	}
}

func mustPack(err error) {
	if err != nil {
		panic(err)
	}
}
