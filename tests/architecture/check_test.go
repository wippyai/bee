// SPDX-License-Identifier: MIT
package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func repoRoot(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "../.."))
}

func loadDeclared(t *testing.T) *Catalog {
	t.Helper()
	root := repoRoot(t)
	if err := CheckRepositoryLayout(root); err != nil {
		t.Fatal(err)
	}
	catalog, err := LoadCatalog(root)
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func loadCatalogWithYAMLMutation(t *testing.T, relative string, mutate func([]byte) []byte) *Catalog {
	t.Helper()
	root := t.TempDir()
	source := filepath.Join(repoRoot(t), "src")
	if err := os.MkdirAll(filepath.Join(root, "src"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS(source)); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, relative)
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, mutate(body), 0600); err != nil {
		t.Fatal(err)
	}
	catalog, err := LoadCatalog(root)
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func insertYAML(t *testing.T, body []byte, marker, insertion string) []byte {
	t.Helper()
	text := string(body)
	index := strings.Index(text, marker)
	if index < 0 {
		t.Fatalf("YAML marker %q not found", marker)
	}
	text = text[:index+len(marker)] + insertion + text[index+len(marker):]
	return []byte(text)
}

func replaceYAML(t *testing.T, body []byte, marker, replacement string) []byte {
	t.Helper()
	text := string(body)
	index := strings.Index(text, marker)
	if index < 0 {
		t.Fatalf("YAML marker %q not found", marker)
	}
	text = text[:index] + replacement + text[index+len(marker):]
	return []byte(text)
}

func TestDeclaredGraphPasses(t *testing.T) {
	catalog := loadDeclared(t)
	if err := CheckDeclaredGraph(catalog); err != nil {
		t.Fatal(err)
	}
	if _, ok := catalog.Entries["bee.governance:db"]; !ok {
		t.Fatal("declared graph must own bee.governance:db")
	}
}

func TestPermissionsViolationRefused(t *testing.T) {
	catalog := loadDeclared(t).clone()
	entry := catalog.Entries["bee:ordinary_app_subsystem_boundary"]
	policy := *entry.Policy
	filtered := make([]any, 0)
	for _, resource := range policy.resourceList() {
		if resource != "bee.governance:db" {
			filtered = append(filtered, resource)
		}
	}
	policy.Resources = filtered
	entry.Policy = &policy
	catalog.Entries["bee:ordinary_app_subsystem_boundary"] = entry
	if err := CheckOrdinaryAppSubsystemBoundary(catalog); err == nil {
		t.Fatal("ordinary apps must be refused when the governance store is not denied")
	}

	catalog = loadDeclared(t).clone()
	settings := catalog.Entries["bee.settings:app"]
	settings.Security = &Security{Policies: []string{"bee:desktop_policy"}}
	catalog.Entries["bee.settings:app"] = settings
	if err := CheckApplicationAdmission(catalog); err == nil {
		t.Fatal("application-owned security must be refused")
	}
}

func TestImportViolationRefused(t *testing.T) {
	catalog := loadDeclared(t).clone()
	layout := catalog.Entries["bee.desktop:layout"]
	layout.Imports = map[string]string{"evil": "poc.legacy:main"}
	catalog.Entries["bee.desktop:layout"] = layout
	if err := CheckEntryDeclarations(catalog); err == nil {
		t.Fatal("poc. imports must be refused")
	}

	catalog = loadDeclared(t).clone()
	model := catalog.Entries["bee.desktop:model"]
	model.Imports = map[string]string{"broker": "bee.applications:broker"}
	catalog.Entries["bee.desktop:model"] = model
	if err := CheckEntryDeclarations(catalog); err == nil {
		t.Fatal("desktop import of broker must be refused")
	}

	catalog = loadDeclared(t).clone()
	core := catalog.Entries["bee.desktop:model"]
	core.Imports = map[string]string{"threads": "bee.threads:client"}
	catalog.Entries["bee.desktop:model"] = core
	if err := CheckLayerBoundaries(catalog); err == nil {
		t.Fatal("core import of threads client must be refused")
	}
}

func TestExtraEntryViolationRefused(t *testing.T) {
	catalog := loadDeclared(t)
	loaded := make([]loadedEntry, 0, len(catalog.Entries)+1)
	for id := range catalog.Entries {
		loaded = append(loaded, loadedEntry{ID: id})
	}
	loaded = append(loaded, loadedEntry{ID: "bee:unexpected_extra"})
	if err := CheckLoadedMatchesDeclared(catalog, loaded); err == nil {
		t.Fatal("extra loaded entry must be refused")
	}

	loaded = loaded[:0]
	for id := range catalog.Entries {
		loaded = append(loaded, loadedEntry{ID: id})
	}
	if err := CheckLoadedMatchesDeclared(catalog, loaded); err != nil {
		t.Fatal(err)
	}
}

func TestOrdinaryBoundaryDeniesGovernanceStore(t *testing.T) {
	catalog := loadDeclared(t)
	if err := CheckOrdinaryAppSubsystemBoundary(catalog); err != nil {
		t.Fatal(err)
	}
	if err := CheckSQLiteInventory(catalog); err != nil {
		t.Fatal(err)
	}
}

func TestExactPoliciesRejectUnknownYAMLFields(t *testing.T) {
	cases := []struct {
		name  string
		entry string
		check func(*Catalog) error
	}{
		{name: "base app", entry: "bee:base_app_policy", check: CheckApplicationAdmission},
		{name: "processes", entry: "bee:processes_policy", check: CheckPresenterProcessTerminalPurity},
		{name: "client storage", entry: "bee:client_storage_policy", check: CheckClientLaunchIdentity},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			catalog := loadCatalogWithYAMLMutation(t, "src/_index.yaml", func(body []byte) []byte {
				name := strings.TrimPrefix(test.entry, "bee:")
				marker := "- name: " + name + "\n  kind: security.policy\n  policy:\n"
				return insertYAML(t, body, marker, "    conditions: []\n")
			})
			entry := catalog.Entries[test.entry]
			if entry.Policy == nil || len(entry.Policy.Extra) != 1 {
				t.Fatalf("unknown policy fields were not retained: %#v", entry.Policy)
			}
			if err := test.check(catalog); err == nil {
				t.Fatal("exact policy comparison accepted an unknown YAML field")
			}
		})
	}
}

func TestTerminalCommandNullKeyIsPresent(t *testing.T) {
	catalog := loadCatalogWithYAMLMutation(t, "src/core/terminal/_index.yaml", func(body []byte) []byte {
		marker := "- name: main\n  kind: process.lua\n  source: file://main.lua\n  method: main\n"
		return insertYAML(t, body, marker, "  meta:\n    command: null\n")
	})
	terminal := catalog.Entries["bee.terminal:main"]
	if !terminal.Meta.CommandPresent {
		t.Fatal("explicit command:null key was decoded as absent")
	}
	if terminal.Meta.Command != nil {
		t.Fatal("command:null should retain a nil command value")
	}
	if err := CheckPresenterProcessTerminalPurity(catalog); err == nil {
		t.Fatal("terminal command:null must be refused")
	}
}

func TestOrdinaryApplicationCommandNullRemainsAllowed(t *testing.T) {
	catalog := loadCatalogWithYAMLMutation(t, "src/apps/settings/_index.yaml", func(body []byte) []byte {
		marker := "  meta:\n    type: bee.application\n"
		return insertYAML(t, body, marker, "    command: null\n")
	})
	settings := catalog.Entries["bee.settings:app"]
	if !settings.Meta.CommandPresent || settings.Meta.Command != nil {
		t.Fatalf("ordinary app command:null was not preserved as a present nil value: %#v", settings.Meta)
	}
	if err := CheckApplicationAdmission(catalog); err != nil {
		t.Fatalf("ordinary app command:null should retain the old truthiness behavior: %v", err)
	}
}

func TestLauncherRejectsScalarYAMLResource(t *testing.T) {
	catalog := loadCatalogWithYAMLMutation(t, "src/_index.yaml", func(body []byte) []byte {
		marker := "- name: local_launcher_spawn_policy\n  kind: security.policy\n  policy:\n    actions: [process.spawn, process.spawn.monitored]\n    resources: [bee.launch:supervisor]\n"
		replacement := "- name: local_launcher_spawn_policy\n  kind: security.policy\n  policy:\n    actions: [process.spawn, process.spawn.monitored]\n    resources: bee.launch:supervisor\n"
		return replaceYAML(t, body, marker, replacement)
	})
	launcher := catalog.Entries["bee:local_launcher_spawn_policy"]
	if launcher.Policy == nil {
		t.Fatal("launcher policy missing")
	}
	if _, ok := launcher.Policy.Resources.(string); !ok {
		t.Fatalf("launcher resource did not retain scalar YAML shape: %#v", launcher.Policy.Resources)
	}
	if err := CheckClientLaunchIdentity(catalog); err == nil {
		t.Fatal("scalar launcher resource must be refused")
	}
}
