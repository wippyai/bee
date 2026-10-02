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
	Input, Output, Version, DependencyVersion string
	Explicit                                  bool
}

type fixturePolicy struct {
	Actions   []string `json:"actions"`
	Resources []string `json:"resources"`
	Effect    string   `json:"effect"`
}

func main() {
	var config struct {
		Packs       []fixturePack
		Sources     map[string]string
		Imports     map[string]map[string]string
		Modules     map[string][]string
		Identity    map[string]any
		Independent map[string]bool
		Policies    map[string]fixturePolicy
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
		for i := range entries {
			if config.Independent[entries[i].ID.String()] {
				if entries[i].Meta == nil {
					mustPack(json.Unmarshal([]byte(`{}`), &entries[i].Meta))
				}
				entries[i].Meta["independent"] = true
			}
		}
		if pack.Explicit && strings.HasPrefix(filepath.Base(pack.Output), "bee-") {
			retained := entries[:0]
			for _, entry := range entries {
				if entry.Kind != "ns.dependency" || !strings.HasPrefix(entry.ID.String(), "bee.deps:") {
					retained = append(retained, entry)
				}
			}
			entries = retained
		}
		for i := range entries {
			entry := &entries[i]
			fields, ok := entry.Data.(map[string]any)
			if !ok {
				continue
			}
			if policy := config.Policies[entry.ID.String()]; policy.Effect != "" {
				fields["policy"] = policy
			}
			if source := config.Sources[entry.ID.String()]; source != "" {
				code, err := os.ReadFile(source)
				mustPack(err)
				fields["source"] = string(code)
				delete(fields, "imports")
				if imports := config.Imports[entry.ID.String()]; len(imports) > 0 {
					fields["imports"] = imports
				}
				delete(fields, "modules")
				if modules := config.Modules[entry.ID.String()]; len(modules) > 0 {
					fields["modules"] = modules
				}
			}
			if entry.Kind == "ns.dependency" {
				component, _ := fields["component"].(string)
				if strings.HasPrefix(component, "bee/") {
					fields["version"] = pack.DependencyVersion
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
