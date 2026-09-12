// SPDX-License-Identifier: MIT
package main

import (
	"path/filepath"
	"runtime"
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
