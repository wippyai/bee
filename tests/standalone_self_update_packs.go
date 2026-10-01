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
	"strings"

	"github.com/wippyai/wapp"
)

type fixturePack struct {
	Input, Output, Version string
}

func main() {
	var config struct {
		Packs    []fixturePack
		Sources  map[string]string
		Identity map[string]any
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
		for i := range entries {
			entry := &entries[i]
			fields, ok := entry.Data.(map[string]any)
			if !ok {
				continue
			}
			if source := config.Sources[entry.ID.String()]; source != "" {
				code, err := os.ReadFile(source)
				mustPack(err)
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
