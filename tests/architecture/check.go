// SPDX-License-Identifier: MIT
package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var anyTypePattern = regexp.MustCompile(`(?:::|:)\s*any\b`)

var desktopInterfaces = map[string]map[string]struct{}{
	"bee.hive.desktop:protocol": stringSet("bee.protocol:application", "bee.application:arguments"),
	"bee.hive.desktop:catalog":  stringSet("bee.protocol:application"),
	"bee.hive.desktop:owner":    stringSet("bee.launch:retained_protocol"),
}

var coreValueInterfaces = map[string]map[string]struct{}{
	"bee.protocol:application": stringSet("bee.threads.records:bounds"),
}

var gatewayConfigurationConsumers = stringSet(
	"bee.harness.carrier:machine",
	"bee.placement.native:service",
	"bee.placement.native:materialization",
)

var appLayerImportExceptions = stringSet(
	"bee.threads:client",
	"bee.threads:protocol",
	"bee.hive:client",
	"bee.hive:types",
	"bee.hive:bounds",
	"bee.threads.records:record",
	"bee.threads.records:types",
	"bee.threads.delivery:session",
	"bee.threads.records:bounds",
	"bee.sync:protocol",
)

var managedWindowInterfaces = map[string]map[string]struct{}{
	"bee.harness.window:app":         stringSet("bee.application:client", "bee.placement.native:window"),
	"bee.harness.window:picker":      stringSet("bee.application:client", "bee.desktop:appearance"),
	"bee.harness.window:picker_view": stringSet("bee.application:text", "bee.desktop:appearance"),
}

var placementSharedImports = stringSet(
	"bee.driver:types",
	"bee.driver:resolver",
	"bee.driver:configuration",
	"bee.driver.kit:quote",
	"bee.threads.records:bounds",
	"bee.threads.records:canonical",
)

var hiveManagerImportPrefixes = []string{"bee.hive_manager:", "bee.application:", "bee.desktop:", "bee.hive:"}

var timelineDeniedResources = stringSet(
	"bee.threads.delivery:claim",
	"bee.threads.delivery:ack",
	"bee.threads.delivery:dispatch",
	"bee.threads.service:record",
	"bee.threads.delivery:unsubscribe",
)

var sqliteInventory = stringSet(
	"bee:workspace_db",
	"bee:client_db",
	"bee.threads:db",
	"bee.placement.native:db",
	"bee.resources:db",
	"bee.credentials:db",
	"bee.approvals:db",
	"bee.gateway:db",
	"bee.node:db",
	"bee.governance:db",
)

var allowedLoadedNamespaces = stringSet(
	"bee",
	"bee.applications",
	"bee.desktop",
	"bee.protocol",
	"bee.host",
	"bee.interaction",
	"bee.launch",
	"bee.node",
	"bee.sync",
	"bee.session",
	"bee.settings",
	"bee.processes",
	"bee.inbox",
	"bee.terminal",
	"bee.workspace",
	"bee.console",
	"bee.application",
	"bee.storage",
	"bee.threads",
	"bee.threads.persist",
	"bee.threads.records",
	"bee.threads.service",
	"bee.hive",
	"bee.hive.telemetry",
	"bee.hive.supervisor",
	"bee.hive.desktop",
	"bee.hive_manager",
	"bee.timeline",
	"bee.client",
	"bee.threads.delivery",
	"bee.threads.projection",
	"bee.threads.carrier",
	"bee.threads.approvals",
	"bee.driver",
	"bee.driver.kit",
	"bee.driver.transport",
	"bee.driver.claude",
	"bee.driver.codex",
	"bee.harness",
	"bee.harness.catalog",
	"bee.harness.carrier",
	"bee.harness.launch",
	"bee.harness.permission",
	"bee.harness.window",
	"bee.persist",
	"bee.placement",
	"bee.placement.native",
	"bee.resources",
	"bee.credentials",
	"bee.approvals",
	"bee.gateway",
	"bee.governance",
)

// CheckRepositoryLayout covers the lock, config, and legacy-archive assertions.
func CheckRepositoryLayout(root string) error {
	if _, err := os.Stat(filepath.Join(root, "legacy")); err == nil {
		return fmt.Errorf("Keep the legacy archive outside the repository")
	} else if !os.IsNotExist(err) {
		return err
	}
	var lock wippyLock
	if err := loadYAML(filepath.Join(root, "wippy.lock"), &lock); err != nil {
		return err
	}
	if lock.Directories.Src != "./src" {
		return fmt.Errorf("Production must load only src/")
	}
	if truthy(lock.Modules) {
		return fmt.Errorf("Core boot must not depend on fixture/test packages")
	}
	var config wippyConfig
	if err := loadYAML(filepath.Join(root, ".wippy.yaml"), &config); err != nil {
		return err
	}
	if truthy(config.Workspace.Replacements) {
		return fmt.Errorf("Review dependency replacements before admitting them")
	}
	return nil
}

// CheckEntryDeclarations covers per-entry structural, permission-source, import,
// source-path/containment, no-any, and native-identity assertions.
func CheckEntryDeclarations(catalog *Catalog) error {
	srcRoot, err := resolvePath(catalog.Src)
	if err != nil {
		return err
	}
	for identity, entry := range catalog.Entries {
		for name, target := range entry.Imports {
			if hasAnyPrefix(target, "poc.", "casha.") {
				return fmt.Errorf("(%s, %s, %s)", identity, name, target)
			}
			if prefixes := restrictedImportPrefixes(identity); prefixes != nil {
				if !hasAnyPrefix(target, prefixes...) {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			}
		}
		if strings.HasPrefix(entry.Source, "file://") {
			indexDir := filepath.Dir(catalog.IndexFiles[identity])
			sourcePath, err := resolvePath(filepath.Join(indexDir, strings.TrimPrefix(entry.Source, "file://")))
			if err != nil {
				return err
			}
			if !containedIn(sourcePath, srcRoot) {
				return fmt.Errorf("(%s, %s)", identity, sourcePath)
			}
			text, err := os.ReadFile(sourcePath)
			if err != nil {
				return fmt.Errorf("%s: %w", identity, err)
			}
			body := string(text)
			if anyTypePattern.MatchString(body) {
				return fmt.Errorf("%s", identity)
			}
			if strings.Contains(body, "/home/") || strings.Contains(body, "legacy/") {
				return fmt.Errorf("%s", identity)
			}
			if identity == "bee.desktop:model" {
				if strings.Contains(body, "require(") || strings.Contains(body, "tty.") {
					return fmt.Errorf("%s", identity)
				}
			}
		}
		if entry.Meta.Type == "bee.application" {
			appsRoot := filepath.Join(catalog.Src, "apps")
			if !containedIn(catalog.IndexFiles[identity], appsRoot) && identity != "bee.harness.window:app" {
				return fmt.Errorf("App outside default package %s", identity)
			}
		}
		if entry.Meta.Type == "test" {
			return fmt.Errorf("%s", identity)
		}
	}
	return nil
}

func restrictedImportPrefixes(identity string) []string {
	if !hasAnyPrefix(identity,
		"bee.desktop:", "bee.session:", "bee.terminal:", "bee.settings:", "bee.processes:", "bee.console:") {
		return nil
	}
	allowed := []string{"bee.desktop:", "bee.protocol:", "bee.application:"}
	if strings.HasPrefix(identity, "bee.terminal:") {
		allowed = append(allowed, "bee.terminal:")
	}
	if strings.HasPrefix(identity, "bee.session:") {
		allowed = append(allowed, "bee.session:")
	}
	if strings.HasPrefix(identity, "bee.processes:") {
		allowed = append(allowed, "bee.processes:")
	}
	if strings.HasPrefix(identity, "bee.settings:") {
		allowed = append(allowed, "bee.settings:")
	}
	if strings.HasPrefix(identity, "bee.console:") {
		allowed = append(allowed, "bee.console:")
	}
	return allowed
}

// CheckHistoricalDesktopAbsent refuses the retired combined desktop identities.
func CheckHistoricalDesktopAbsent(catalog *Catalog) error {
	if _, ok := catalog.Entries["bee.workspace:main"]; ok {
		return fmt.Errorf("Historical combined desktop must not ship")
	}
	if _, ok := catalog.Entries["bee.workspace:launch"]; ok {
		return fmt.Errorf("Historical combined desktop must not ship")
	}
	return nil
}

// CheckImportTargetsExist requires every import to name a declared identity.
func CheckImportTargetsExist(catalog *Catalog) error {
	for _, entry := range catalog.Entries {
		for _, target := range entry.Imports {
			if _, ok := catalog.Entries[target]; !ok {
				return fmt.Errorf("%s", target)
			}
		}
	}
	return nil
}

// CheckApplicationAdmission covers application/admission cardinality, base
// policies, and per-application metadata/authority assertions.
func CheckApplicationAdmission(catalog *Catalog) error {
	admission, err := catalog.require("bee:application_admission")
	if err != nil {
		return err
	}
	applications := catalog.applications()
	bound := map[string]struct{}{}
	for _, binding := range admission.Bindings {
		bound[binding.DefinitionID] = struct{}{}
	}
	if !equalSet(bound, setKeys(applications)...) || len(admission.Bindings) != len(applications) {
		return fmt.Errorf("application admission bindings differ from declared applications")
	}
	base, err := catalog.require("bee:base_app_policy")
	if err != nil {
		return err
	}
	if base.Policy == nil || len(base.Policy.Extra) != 0 || base.Policy.Effect != "allow" ||
		!slicesEqual(base.Policy.Actions, []string{"process.send"}) ||
		!resourcesEqual(base.Policy.Resources, "*") {
		return fmt.Errorf("bee:base_app_policy mismatch")
	}
	boundary, err := catalog.require("bee:app_boundary_policy")
	if err != nil {
		return err
	}
	if boundary.Policy == nil || boundary.Policy.Effect != "deny" || !resourcesEqual(boundary.Policy.Resources, "*") {
		return fmt.Errorf("bee:app_boundary_policy mismatch")
	}
	if !containsAll(boundary.Policy.Actions,
		"process.security", "process.context", "security.policy.get", "security.scope.create",
		"registry.apply", "registry.apply_version", "registry.overlay.apply") {
		return fmt.Errorf("bee:app_boundary_policy missing denied actions")
	}
	for identity := range applications {
		entry := catalog.Entries[identity]
		if entry.Kind != "process.lua" {
			return fmt.Errorf("%s kind %s", identity, entry.Kind)
		}
		if entry.autoStart() {
			return fmt.Errorf("%s auto-starts", identity)
		}
		if entry.Meta.Command != nil {
			return fmt.Errorf("%s declares a command", identity)
		}
		if entry.hasSecurity() {
			return fmt.Errorf("Authority comes from protected admission")
		}
		metadata := entry.Meta.Application
		if metadata == nil || metadata.APIVersion != 1 || !truthy(metadata.Revision) {
			return fmt.Errorf("%s application metadata", identity)
		}
		if metadata.InstancePolicy != "singleton" && metadata.InstancePolicy != "multiple" {
			return fmt.Errorf("%s instance_policy %s", identity, metadata.InstancePolicy)
		}
	}
	return nil
}

func setKeys(values map[string]struct{}) []string {
	out := make([]string, 0, len(values))
	for value := range values {
		out = append(out, value)
	}
	return out
}

// CheckValueInterfaceClosures walks desktop, application-envelope, and placement
// type libraries and refuses runtime modules or security policy.
func CheckValueInterfaceClosures(catalog *Catalog) error {
	checked := map[string]struct{}{}
	var check func(string) error
	check = func(identity string) error {
		if _, seen := checked[identity]; seen {
			return nil
		}
		checked[identity] = struct{}{}
		entry, err := catalog.require(identity)
		if err != nil {
			return err
		}
		if entry.Kind != "library.lua" {
			return fmt.Errorf("Interface is not a value library %s", identity)
		}
		if entry.hasModules() || entry.hasSecurity() {
			return fmt.Errorf("Interface gained runtime authority %s", identity)
		}
		for _, dependency := range entry.Imports {
			if err := check(dependency); err != nil {
				return err
			}
		}
		return nil
	}
	for _, interfaces := range desktopInterfaces {
		for identity := range interfaces {
			if err := check(identity); err != nil {
				return err
			}
		}
	}
	for _, interfaces := range coreValueInterfaces {
		for identity := range interfaces {
			if err := check(identity); err != nil {
				return err
			}
		}
	}
	return check("bee.placement:types")
}

// CheckDriverContractClosures requires generic driver contracts to stay inside
// bee.driver and bee.threads.records.
func CheckDriverContractClosures(catalog *Catalog) error {
	var check func(string, map[string]struct{}) error
	check = func(identity string, seen map[string]struct{}) error {
		if _, ok := seen[identity]; ok {
			return nil
		}
		seen[identity] = struct{}{}
		namespace, _, ok := strings.Cut(identity, ":")
		if !ok {
			return fmt.Errorf("Provider dependency in generic driver contract %s", identity)
		}
		if namespace != "bee.driver" && namespace != "bee.threads.records" {
			return fmt.Errorf("Provider dependency in generic driver contract %s", identity)
		}
		entry, err := catalog.require(identity)
		if err != nil {
			return err
		}
		for _, dependency := range entry.Imports {
			if err := check(dependency, seen); err != nil {
				return err
			}
		}
		return nil
	}
	for _, identity := range []string{"bee.driver:resolver", "bee.driver:configuration"} {
		if err := check(identity, map[string]struct{}{}); err != nil {
			return err
		}
	}
	return nil
}

// CheckLayerBoundaries covers the production folder import graph.
func CheckLayerBoundaries(catalog *Catalog) error {
	for identity, entry := range catalog.Entries {
		location := catalog.Locations[identity]
		for _, target := range entry.Imports {
			targetLocation, ok := catalog.Locations[target]
			if !ok {
				return fmt.Errorf("%s", target)
			}
			layer := firstPart(location)
			targetLayer := firstPart(targetLocation)
			switch layer {
			case "core":
				if targetLayer != "core" && targetLayer != "ui" {
					if _, allowed := coreValueInterfaces[identity][target]; !allowed {
						return fmt.Errorf("(%s, %s)", identity, target)
					}
				}
			case "ui":
				if targetLayer != "ui" {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			case "apps":
				if targetLayer != "ui" && prefix2(targetLocation) != prefix2(location) {
					if _, allowed := appLayerImportExceptions[target]; !allowed {
						return fmt.Errorf("(%s, %s)", identity, target)
					}
				}
			case "threads":
				if targetLayer != "threads" && !strings.HasPrefix(target, "bee.persist:") {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			case "placement":
				if targetLayer != "placement" && targetLayer != "persist" {
					if _, allowed := placementSharedImports[target]; !allowed {
						if _, consumer := gatewayConfigurationConsumers[identity]; !consumer || target != "bee.gateway:configuration" {
							return fmt.Errorf("(%s, %s)", identity, target)
						}
					}
				}
			case "credentials":
				if targetLayer != "credentials" && targetLayer != "persist" && !strings.HasPrefix(target, "bee.threads.records:") {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			case "approvals":
				if targetLayer != "approvals" && targetLayer != "persist" && !strings.HasPrefix(target, "bee.threads.records:") {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			case "resources":
				if targetLayer != "resources" && targetLayer != "persist" && !strings.HasPrefix(target, "bee.threads.records:") {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			case "persist":
				if targetLayer != "persist" {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			case "driver":
				if targetLayer != "driver" && !strings.HasPrefix(target, "bee.threads.records:") {
					return fmt.Errorf("(%s, %s)", identity, target)
				}
			case "harness":
				if secondPart(location) == "carrier" {
					if targetLayer != "harness" && targetLayer != "driver" && targetLayer != "placement" && !strings.HasPrefix(target, "bee.threads.records:") {
						if _, consumer := gatewayConfigurationConsumers[identity]; !consumer || target != "bee.gateway:configuration" {
							return fmt.Errorf("(%s, %s)", identity, target)
						}
					}
				} else if targetLayer != "harness" && targetLayer != "driver" && !strings.HasPrefix(target, "bee.threads.records:") {
					admissionTypes := identity == "bee.harness.launch:admission" && target == "bee.placement:types"
					_, managed := managedWindowInterfaces[identity][target]
					if !admissionTypes && !managed {
						return fmt.Errorf("(%s, %s)", identity, target)
					}
				}
			case "hive":
				if targetLayer != "hive" && target != "bee.threads.records:canonical" {
					if _, allowed := desktopInterfaces[identity][target]; !allowed {
						return fmt.Errorf("(%s, %s)", identity, target)
					}
				}
			}
		}
	}
	return nil
}

// CheckImportCycles refuses a cyclic import graph.
func CheckImportCycles(catalog *Catalog) error {
	visiting := map[string]struct{}{}
	visited := map[string]struct{}{}
	var visit func(string) error
	visit = func(identity string) error {
		if _, ok := visiting[identity]; ok {
			return fmt.Errorf("Import cycle %s", identity)
		}
		if _, ok := visited[identity]; ok {
			return nil
		}
		visiting[identity] = struct{}{}
		for _, target := range catalog.Entries[identity].Imports {
			if err := visit(target); err != nil {
				return err
			}
		}
		delete(visiting, identity)
		visited[identity] = struct{}{}
		return nil
	}
	for identity := range catalog.Entries {
		if err := visit(identity); err != nil {
			return err
		}
	}
	return nil
}

// CheckCoreOmitsApplicationIdentities refuses bundled-app IDs inside core Lua.
func CheckCoreOmitsApplicationIdentities(catalog *Catalog) error {
	applications := catalog.applications()
	ids := setKeys(applications)
	core := filepath.Join(catalog.Src, "core")
	return filepath.WalkDir(core, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".lua") {
			return nil
		}
		text, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		body := string(text)
		for _, identity := range ids {
			if strings.Contains(body, identity) {
				return fmt.Errorf("%s", path)
			}
		}
		return nil
	})
}

// CheckPresenterProcessTerminalPurity covers presenter/process-manager/terminal
// native identity and pure-module assertions.
func CheckPresenterProcessTerminalPurity(catalog *Catalog) error {
	presenter, err := catalog.require("bee:presenter_policy")
	if err != nil {
		return err
	}
	if presenter.Policy == nil || !equalStringSet(presenter.Policy.Actions,
		"tty.observe", "tty.input", "tty.resize", "process.send", "process.monitor") {
		return fmt.Errorf("bee:presenter_policy actions")
	}
	processes, err := catalog.require("bee:processes_policy")
	if err != nil {
		return err
	}
	if processes.Policy == nil || len(processes.Policy.Extra) != 0 || processes.Policy.Effect != "allow" ||
		!slicesEqual(processes.Policy.Actions, []string{"system.read"}) ||
		!resourcesEqual(processes.Policy.Resources, []string{"hosts", "memory", "goroutines", "supervisor"}) {
		return fmt.Errorf("bee:processes_policy mismatch")
	}
	processesApp, err := catalog.require("bee.processes:app")
	if err != nil {
		return err
	}
	if processesApp.autoStart() {
		return fmt.Errorf("bee.processes:app auto-starts")
	}
	terminal, err := catalog.require("bee.terminal:main")
	if err != nil {
		return err
	}
	if terminal.containsModule("security") {
		return fmt.Errorf("bee.terminal:main modules include security")
	}
	if terminal.Meta.CommandPresent {
		return fmt.Errorf("bee.terminal:main declares a command")
	}
	render, err := catalog.require("bee.terminal:render")
	if err != nil {
		return err
	}
	if !slicesEqual(render.Modules, []string{"tty"}) {
		return fmt.Errorf("bee.terminal:render modules")
	}
	for _, identity := range []string{"bee.desktop:layout", "bee.terminal:bindings"} {
		entry, err := catalog.require(identity)
		if err != nil {
			return err
		}
		if entry.hasModules() {
			return fmt.Errorf("%s", identity)
		}
	}
	return nil
}

// CheckPureSyncProtocol walks bee.sync:protocol and refuses runtime authority.
func CheckPureSyncProtocol(catalog *Catalog) error {
	checked := map[string]struct{}{}
	var check func(string) error
	check = func(identity string) error {
		if _, ok := checked[identity]; ok {
			return nil
		}
		checked[identity] = struct{}{}
		entry, err := catalog.require(identity)
		if err != nil {
			return err
		}
		if entry.Kind != "library.lua" {
			return fmt.Errorf("%s", identity)
		}
		if entry.hasModules() || entry.hasSecurity() {
			return fmt.Errorf("%s", identity)
		}
		for _, dependency := range entry.Imports {
			if err := check(dependency); err != nil {
				return err
			}
		}
		return nil
	}
	return check("bee.sync:protocol")
}

// CheckSQLiteInventory requires the exact owned SQLite set, including governance.
func CheckSQLiteInventory(catalog *Catalog) error {
	got := map[string]struct{}{}
	for id, entry := range catalog.Entries {
		if entry.Kind == "db.sql.sqlite" {
			got[id] = struct{}{}
		}
	}
	if !equalSet(got, setKeys(sqliteInventory)...) {
		return fmt.Errorf("sqlite inventory %v", setKeys(got))
	}
	return nil
}

func CheckTerminalHostInventory(catalog *Catalog) error {
	got := map[string]struct{}{}
	for id, entry := range catalog.Entries {
		if entry.Kind == "terminal.host" {
			got[id] = struct{}{}
		}
	}
	if !equalSet(got, "bee:terminal") {
		return fmt.Errorf("terminal.host inventory %v", setKeys(got))
	}
	return nil
}

// CheckOrdinaryAppSubsystemBoundary requires ordinary apps to deny placement,
// resources, credentials, and governance stores.
func CheckOrdinaryAppSubsystemBoundary(catalog *Catalog) error {
	entry, err := catalog.require("bee:ordinary_app_subsystem_boundary")
	if err != nil {
		return err
	}
	if entry.Policy == nil || entry.Policy.Effect != "deny" {
		return fmt.Errorf("bee:ordinary_app_subsystem_boundary must deny")
	}
	for _, resource := range []string{
		"bee.placement.native:db",
		"bee.resources:db",
		"bee.credentials:db",
		"bee.governance:db",
	} {
		if !entry.Policy.containsResource(resource) {
			return fmt.Errorf("ordinary_app_subsystem_boundary missing %s", resource)
		}
	}
	return nil
}

// CheckWorkspaceStorageBoundary covers workspace/client store denial and the
// approvals-store exception.
func CheckWorkspaceStorageBoundary(catalog *Catalog) error {
	boundary, err := catalog.require("bee:workspace_storage_boundary")
	if err != nil {
		return err
	}
	if boundary.Policy == nil || !equalStringSet(boundary.Policy.resourceList(),
		"bee:workspace_db", "bee:client_db", "bee.client.db:*", "bee.workspace.db:*") {
		return fmt.Errorf("bee:workspace_storage_boundary resources")
	}
	if boundary.Policy.containsResource("bee.approvals:db") {
		return fmt.Errorf("bee.approvals:db must not be on the workspace storage deny list")
	}
	if !boundary.Policy.containsResource("bee:client_db") {
		return fmt.Errorf("bee:client_db missing from workspace storage boundary")
	}
	return nil
}

// CheckOrdinaryAdmissionPolicies covers ordinary-app, managed-window, inbox,
// hive-manager, and timeline admission rows.
func CheckOrdinaryAdmissionPolicies(catalog *Catalog) error {
	admission, err := catalog.require("bee:application_admission")
	if err != nil {
		return err
	}
	for _, binding := range admission.Bindings {
		if binding.DefinitionID == "bee.harness.window:app" {
			continue
		}
		if !containsAll(binding.Policies, "bee:ordinary_app_subsystem_boundary") {
			return fmt.Errorf("%s", binding.DefinitionID)
		}
	}
	managed, ok := bindingByID(admission.Bindings, "bee.harness.window:app")
	if !ok {
		return fmt.Errorf("missing bee.harness.window:app admission")
	}
	if !equalStringSet(managed.Policies,
		"bee:carrier_policy", "bee:placement_store_policy", "bee:placement_exec_policy", "bee:placement_runner_policy",
		"bee:resource_resolve_policy", "bee:credential_materialize_policy", "bee:gateway_materialize_policy", "bee:gateway_supervision_policy") {
		return fmt.Errorf("bee.harness.window:app policies")
	}
	inbox, ok := bindingByID(admission.Bindings, "bee.inbox:app")
	if !ok {
		return fmt.Errorf("missing bee.inbox:app admission")
	}
	if !equalStringSet(inbox.Policies, "bee:ordinary_app_subsystem_boundary", "bee:approval_decide_policy", "bee.inbox:client_policy") {
		return fmt.Errorf("bee.inbox:app policies")
	}
	inboxPolicy, err := catalog.require("bee.inbox:client_policy")
	if err != nil {
		return err
	}
	if inboxPolicy.Policy == nil || !equalStringSet(inboxPolicy.Policy.Actions, "funcs.call", "registry.get") {
		return fmt.Errorf("bee.inbox:client_policy actions")
	}
	if inboxPolicy.Policy.containsResource("bee.approvals:list") {
		return fmt.Errorf("bee.approvals:list in inbox client policy")
	}
	manager, ok := bindingByID(admission.Bindings, "bee.hive_manager:app")
	if !ok {
		return fmt.Errorf("missing bee.hive_manager:app admission")
	}
	if !equalStringSet(manager.Policies, "bee:ordinary_app_subsystem_boundary", "bee.hive_manager:client_policy") {
		return fmt.Errorf("bee.hive_manager:app policies")
	}
	if !manager.CatalogRead {
		return fmt.Errorf("bee.hive_manager:app catalog_read")
	}
	for _, binding := range admission.Bindings {
		if binding.DefinitionID != "bee.hive_manager:app" && binding.CatalogRead {
			return fmt.Errorf("%s catalog_read", binding.DefinitionID)
		}
	}
	managerPolicy, err := catalog.require("bee.hive_manager:client_policy")
	if err != nil {
		return err
	}
	if managerPolicy.Policy == nil || !equalStringSet(managerPolicy.Policy.Actions, "registry.get", "system.read") {
		return fmt.Errorf("bee.hive_manager:client_policy actions")
	}
	source, err := catalog.require("bee.hive_manager:source")
	if err != nil {
		return err
	}
	if len(source.Data) != 1 || fmt.Sprint(source.Data["kind"]) != "live" {
		return fmt.Errorf("Production ships the live directory; a fixture is an explicit host selection")
	}
	timeline, ok := bindingByID(admission.Bindings, "bee.timeline:app")
	if !ok {
		return fmt.Errorf("missing bee.timeline:app admission")
	}
	if !equalStringSet(timeline.Policies, "bee:ordinary_app_subsystem_boundary", "bee.timeline:client_policy") {
		return fmt.Errorf("bee.timeline:app policies")
	}
	timelinePolicy, err := catalog.require("bee.timeline:client_policy")
	if err != nil {
		return err
	}
	if timelinePolicy.Policy == nil {
		return fmt.Errorf("bee.timeline:client_policy missing")
	}
	for _, resource := range timelinePolicy.Policy.resourceList() {
		if _, denied := timelineDeniedResources[resource]; denied {
			return fmt.Errorf("Viewing acknowledges no delivery and writes nothing")
		}
	}
	return nil
}

// CheckHiveManagerImports restricts hive-manager identities to their public surfaces.
func CheckHiveManagerImports(catalog *Catalog) error {
	for identity, entry := range catalog.Entries {
		if !strings.HasPrefix(identity, "bee.hive_manager:") {
			continue
		}
		for _, target := range entry.Imports {
			if !hasAnyPrefix(target, hiveManagerImportPrefixes...) {
				return fmt.Errorf("(%s, %s)", identity, target)
			}
		}
	}
	return nil
}

// CheckApprovalStorePolicies requires store policy on owner methods.
func CheckApprovalStorePolicies(catalog *Catalog) error {
	for _, method := range []string{"inbox", "read", "decide", "withdraw"} {
		identity := "bee.approvals:" + method
		entry, err := catalog.require(identity)
		if err != nil {
			return err
		}
		if entry.Security == nil || !containsAll(entry.Security.Policies, "bee:approval_store_policy") {
			return fmt.Errorf("%s missing bee:approval_store_policy", identity)
		}
	}
	return nil
}

// CheckClientLaunchIdentity covers client storage, launch commands, and spawn boundary.
func CheckClientLaunchIdentity(catalog *Catalog) error {
	storage, err := catalog.require("bee:client_storage_policy")
	if err != nil {
		return err
	}
	if storage.Policy == nil || len(storage.Policy.Extra) != 0 || storage.Policy.Effect != "allow" ||
		!slicesEqual(storage.Policy.Actions, []string{"db.get"}) ||
		!resourcesEqual(storage.Policy.Resources, []string{"bee:client_db"}) {
		return fmt.Errorf("bee:client_storage_policy mismatch")
	}
	clientDB, err := catalog.require("bee:client_db")
	if err != nil {
		return err
	}
	if clientDB.File != "${env:bee:workspace_db_path}.client" {
		return fmt.Errorf("bee:client_db file")
	}
	commands := map[string]string{
		"bee.client:desktop":     "bee",
		"bee.client:application": "bee-app",
	}
	spawn, err := catalog.require("bee:core_spawn_boundary")
	if err != nil {
		return err
	}
	for identity, command := range commands {
		entry, err := catalog.require(identity)
		if err != nil {
			return err
		}
		if entry.Meta.Command == nil || entry.Meta.Command.Name != command {
			return fmt.Errorf("%s command", identity)
		}
		if !equalStringSet(entry.Meta.Command.Security.Policies,
			"bee:desktop_policy", "bee:client_spawn_policy", "bee:client_storage_policy", "bee:local_launcher_spawn_policy") {
			return fmt.Errorf("%s command policies", identity)
		}
		if spawn.Policy == nil || !spawn.Policy.containsResource(identity) {
			return fmt.Errorf("%s missing from core spawn boundary", identity)
		}
	}
	launcher, err := catalog.require("bee:local_launcher_spawn_policy")
	if err != nil {
		return err
	}
	if launcher.Policy == nil || !resourcesEqual(launcher.Policy.Resources, []string{"bee.launch:supervisor"}) {
		return fmt.Errorf("bee:local_launcher_spawn_policy resources")
	}
	return nil
}

// CheckNoHTTPService refuses http.service entries in production.
func CheckNoHTTPService(catalog *Catalog) error {
	for _, entry := range catalog.Entries {
		if entry.Kind == "http.service" {
			return fmt.Errorf("http.service is not a production entry")
		}
	}
	return nil
}

// CheckDeclaredGraph runs every source-graph assertion except loaded-inventory CLI reads.
func CheckDeclaredGraph(catalog *Catalog) error {
	checks := []func(*Catalog) error{
		CheckEntryDeclarations,
		CheckHistoricalDesktopAbsent,
		CheckImportTargetsExist,
		CheckApplicationAdmission,
		CheckValueInterfaceClosures,
		CheckDriverContractClosures,
		CheckLayerBoundaries,
		CheckImportCycles,
		CheckCoreOmitsApplicationIdentities,
		CheckPresenterProcessTerminalPurity,
		CheckPureSyncProtocol,
		CheckTerminalHostInventory,
		CheckSQLiteInventory,
		CheckOrdinaryAppSubsystemBoundary,
		CheckWorkspaceStorageBoundary,
		CheckOrdinaryAdmissionPolicies,
		CheckHiveManagerImports,
		CheckApprovalStorePolicies,
		CheckClientLaunchIdentity,
		CheckNoHTTPService,
	}
	for _, check := range checks {
		if err := check(catalog); err != nil {
			return err
		}
	}
	return nil
}
