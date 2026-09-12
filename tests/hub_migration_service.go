// SPDX-License-Identifier: MIT
// Real Hub facade/publication/migration acceptance against disposable artifacts.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/wippyai/wapp"
)

type packageEntry struct {
	Namespace string         `json:"ns"`
	Name      string         `json:"name"`
	Kind      string         `json:"kind"`
	Data      map[string]any `json:"data,omitempty"`
	Meta      map[string]any `json:"meta,omitempty"`
}

func repoRoot() (string, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	if filepath.Base(cwd) == "native" {
		return filepath.Dir(cwd), nil
	}
	return cwd, nil
}

func copyServiceFile(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("read %s: %w", source, err)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(destination, data, 0600); err != nil {
		return fmt.Errorf("write %s: %w", destination, err)
	}
	return nil
}

func prepareFixture(root, repo string) error {
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join(repo, "tests/fixtures/hub_manage"))); err != nil {
		return fmt.Errorf("copy Hub fixture: %w", err)
	}
	if err := os.CopyFS(filepath.Join(root, "src/hub"), os.DirFS(filepath.Join(repo, "src/hub"))); err != nil {
		return fmt.Errorf("copy production Hub source: %w", err)
	}
	if err := copyServiceFile(filepath.Join(repo, "src/threads/records/bounds.lua"), filepath.Join(root, "src/records/bounds.lua")); err != nil {
		return err
	}
	for _, name := range []string{"bounds.lua", "canonical.lua"} {
		if err := copyServiceFile(filepath.Join(repo, "src/sync", name), filepath.Join(root, "src/sync", name)); err != nil {
			return err
		}
	}
	if err := copyServiceFile(filepath.Join(repo, "src/persist/transaction.lua"), filepath.Join(root, "src/persist/transaction.lua")); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "src/persist/_index.yaml"), []byte("version: '1.0'\nnamespace: bee.persist\nentries:\n- name: transaction\n  kind: library.lua\n  source: file://transaction.lua\n  modules: [sql, time]\n"), 0600); err != nil {
		return err
	}
	if err := copyServiceFile(filepath.Join(repo, "wippy.lock"), filepath.Join(root, "wippy.lock")); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nregistry:\n  enable_history: true\n  history_type: sqlite\n  history_path: registry.db\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return err
	}
	return nil
}

func serviceIndex(mode string) string {
	migrationMethod := mode
	if mode == "tamper" {
		migrationMethod = "crash"
	}
	if mode == "partial" {
		migrationMethod = "partial"
	}
	if mode == "linked" {
		migrationMethod = "linked"
	}
	if mode == "crash" {
		migrationMethod = "crash"
	}
	return fmt.Sprintf(`version: '1.0'
namespace: probe
entries:
- name: db
  kind: db.sql.sqlite
  file: .wippy/migration.db
- name: caller
  kind: security.policy
  policy:
    actions: [funcs.call]
    resources: [bee.hub:call]
    effect: allow
- name: manage
  kind: security.policy
  policy:
    actions: [bee.hub.manage]
    resources: [acme/app]
    effect: allow
- name: read
  kind: security.policy
  policy:
    actions: [registry.get, bee.hub.read]
    resources: '*'
    effect: allow
- name: migration_function
  kind: security.policy
  groups: [bee.hub:execution_scope]
  policy:
    actions: [funcs.call]
    resources: [acme.storage:first, acme.storage:second]
    effect: allow
- name: run
  kind: process.lua
  source: file://probe.lua
  method: %s
  modules: [funcs, registry, logger, sql]
  security:
    policies: [probe:caller, probe:manage, probe:read]
  meta:
    command:
      name: migration-service-probe
      security:
        actor: {id: probe.migration_service}
`, migrationMethod)
}

func appendPolicy(index, name, actions, resources string, groups ...string) string {
	groupLine := ""
	if len(groups) > 0 {
		groupLine = fmt.Sprintf("  groups: [%s]\n", strings.Join(groups, ", "))
	}
	if resources == "*" {
		resources = "'*'"
	}
	return index + fmt.Sprintf(`- name: %s
  kind: security.policy
%s
  policy:
    actions: [%s]
    resources: [%s]
    effect: allow
`, name, groupLine, actions, resources)
}

func runEnvironment(folder, hubURL string) []string {
	return []string{
		"HOME=" + os.Getenv("HOME"),
		"PATH=" + os.Getenv("PATH"),
		"WIPPY_REGISTRY=" + hubURL,
		"XDG_CONFIG_HOME=" + filepath.Join(folder, "config"),
	}
}

func runRuntime(ctx context.Context, runtime, folder string, environment []string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir = folder
	cmd.Env = environment
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
	cmd.WaitDelay = 3 * time.Second
	return cmd.CombinedOutput()
}

func buildFixtureBinary(repo, destination string) error {
	cmd := exec.Command("go", "build", "-mod=readonly", "-o", destination, filepath.Join(repo, "tests/hub_migration_fixture.go"))
	cmd.Dir = filepath.Join(repo, "native")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("build Hub fixture: %w\n%s", err, output)
	}
	return nil
}

func packageEntryFor(namespace, name, kind string, data, meta map[string]any) wapp.Entry {
	if data == nil {
		data = map[string]any{}
	}
	if meta == nil {
		meta = map[string]any{}
	}
	return wapp.Entry{ID: wapp.NewID(namespace, name), Kind: kind, Data: data, Meta: meta}
}

func startFixtureServer(binary, descriptions, logPath string) (*exec.Cmd, *os.File, string, error) {
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return nil, nil, "", err
	}
	cmd := exec.Command(binary, descriptions)
	cmd.Stdout = nil
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = log.Close()
		return nil, nil, "", err
	}
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		_ = log.Close()
		return nil, nil, "", err
	}
	lines := make(chan string, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		if scanner.Scan() {
			lines <- scanner.Text()
			return
		}
		lines <- ""
	}()
	select {
	case url := <-lines:
		if !strings.HasPrefix(url, "http://127.0.0.1:") {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			_ = cmd.Wait()
			_ = log.Close()
			return nil, nil, "", fmt.Errorf("fixture Hub announced invalid listener %q", url)
		}
		return cmd, log, url, nil
	case <-time.After(15 * time.Second):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
		_ = log.Close()
		return nil, nil, "", fmt.Errorf("fixture Hub did not announce its listener")
	}
}

func killAfterCommit(runtime, folder string, environment []string) error {
	output, err := os.OpenFile(filepath.Join(folder, "crash-runtime.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer output.Close()
	cmd := exec.Command(runtime, "run", "--verbose", "--host", "bee:workers", "--", "migration-service-probe")
	cmd.Dir = folder
	cmd.Env = environment
	cmd.Stdout = output
	cmd.Stderr = output
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	waitDone := make(chan error, 1)
	go func() { waitDone <- cmd.Wait() }()
	waited := false
	defer func() {
		if !waited {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-waitDone
		}
	}()
	marker := "HUB_MIGRATION_SCHEMA_COMMITTED"
	deadline := time.Now().Add(45 * time.Second)
	seen := false
	for time.Now().Before(deadline) {
		data, readErr := os.ReadFile(filepath.Join(folder, "crash-runtime.log"))
		if readErr == nil && strings.Contains(string(data), marker) {
			seen = true
			break
		}
		select {
		case waitErr := <-waitDone:
			waited = true
			data, _ := os.ReadFile(filepath.Join(folder, "crash-runtime.log"))
			return fmt.Errorf("publication process exited before crash marker: %v\n%s", waitErr, data)
		default:
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !seen {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-waitDone
		waited = true
		data, _ := os.ReadFile(filepath.Join(folder, "crash-runtime.log"))
		return fmt.Errorf("publication crash marker was not observed\n%s", data)
	}
	killErr := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	err = <-waitDone
	waited = true
	status, ok := cmd.ProcessState.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
		return fmt.Errorf("fixture runtime was not SIGKILLed (kill=%v wait=%v)", killErr, err)
	}
	return nil
}

func checkServiceDatabase(folder, mode string) error {
	database := filepath.Join(folder, ".wippy/migration.db")
	rows, err := sqlLines(database, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
	if err != nil {
		return err
	}
	want := ""
	switch mode {
	case "applied", "crash", "tamper", "linked":
		want = "_migrations,fixture_payload"
	case "partial":
		want = "_migrations,fixture_gate,fixture_payload,fixture_second"
	}
	if strings.Join(rows, ",") != want {
		return fmt.Errorf("%s database tables = %v, want %s", mode, rows, want)
	}
	if want == "" {
		return nil
	}
	rows, err = sqlLines(database, "SELECT id FROM _migrations ORDER BY id")
	if err != nil {
		return err
	}
	if mode == "partial" {
		if strings.Join(rows, ",") != "acme.storage:first,acme.storage:second" {
			return fmt.Errorf("partial migration ledger = %v", rows)
		}
	} else if strings.Join(rows, ",") != "acme.storage:first" {
		return fmt.Errorf("%s migration ledger = %v", mode, rows)
	}
	rows, err = sqlLines(database, "SELECT value FROM fixture_payload")
	if err != nil {
		return err
	}
	if strings.Join(rows, ",") != "committed" {
		return fmt.Errorf("%s payload = %v", mode, rows)
	}
	if mode == "partial" {
		rows, err = sqlLines(database, "SELECT value FROM fixture_second")
		if err != nil {
			return err
		}
		if strings.Join(rows, ",") != "committed" {
			return fmt.Errorf("partial second payload = %v", rows)
		}
	}
	return nil
}

func sqlLines(database, query string) ([]string, error) {
	output, err := exec.Command("sqlite3", "-readonly", "-batch", "-noheader", database, query).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("sqlite3: %w: %s", err, strings.TrimSpace(string(output)))
	}
	value := strings.TrimSpace(string(output))
	if value == "" {
		return nil, nil
	}
	return strings.Split(value, "\n"), nil
}

func runMode(runtime, folder, hubURL, mode string) error {
	if err := os.MkdirAll(filepath.Join(folder, "src/migration_probe"), 0700); err != nil {
		return err
	}
	if err := copyServiceFile(filepath.Join(folder, "repo-probe.lua"), filepath.Join(folder, "src/migration_probe/probe.lua")); err != nil {
		return err
	}
	index := serviceIndex(mode)
	if mode == "tamper" {
		index = appendPolicy(index, "fixture_operator", "registry.apply, registry.update.function.lua", "*")
		index = strings.Replace(index, "[probe:caller, probe:manage, probe:read]", "[probe:caller, probe:manage, probe:read, probe:fixture_operator]", 1)
	}
	if mode == "partial" {
		index = appendPolicy(index, "fixture_prerequisite", "db.get", "probe:db")
		index = strings.Replace(index, "[probe:caller, probe:manage, probe:read]", "[probe:caller, probe:manage, probe:read, probe:fixture_prerequisite]", 1)
	}
	if mode != "denied" {
		index = appendPolicy(index, "migration_database", "db.get", "probe:db", "bee.hub:execution_scope")
	}
	if err := os.WriteFile(filepath.Join(folder, "src/migration_probe/_index.yaml"), []byte(index), 0600); err != nil {
		return err
	}
	environment := runEnvironment(folder, hubURL)
	if mode == "crash" || mode == "tamper" {
		service := filepath.Join(folder, "src/hub/service.lua")
		original, err := os.ReadFile(service)
		if err != nil {
			return err
		}
		anchor := "    if result then work.rows = result.rows end\n"
		if strings.Count(string(original), anchor) != 1 {
			return fmt.Errorf("migration service injection anchor is not unique")
		}
		injected := strings.Replace(string(original), anchor, anchor+"    print(\"HUB_MIGRATION_SCHEMA_COMMITTED\")\n    while true do end\n", 1)
		if err := os.WriteFile(service, []byte(injected), 0600); err != nil {
			return err
		}
		if err := killAfterCommit(runtime, folder, environment); err != nil {
			_ = os.WriteFile(service, original, 0600)
			return err
		}
		if err := os.WriteFile(service, original, 0600); err != nil {
			return err
		}
		data, err := os.ReadFile(filepath.Join(folder, "src/migration_probe/_index.yaml"))
		if err != nil {
			return err
		}
		method := "recover"
		if mode == "tamper" {
			method = "tamper"
		}
		updated := strings.Replace(string(data), "method: crash", "method: "+method, 1)
		if err := os.WriteFile(filepath.Join(folder, "src/migration_probe/_index.yaml"), []byte(updated), 0600); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	output, err := runRuntime(ctx, runtime, folder, environment, "run", "--verbose", "--host", "bee:workers", "--", "migration-service-probe")
	if writeErr := os.WriteFile(filepath.Join(folder, "runtime.log"), output, 0600); writeErr != nil {
		return writeErr
	}
	if err != nil {
		return fmt.Errorf("%s runtime failed: %w\n%s", mode, err, output)
	}
	if !strings.Contains(string(output), "HUB_MIGRATION_SERVICE_PASS "+mode) {
		return fmt.Errorf("%s omitted acceptance marker\n%s", mode, output)
	}
	return checkServiceDatabase(folder, mode)
}

func run() error {
	repo, err := repoRoot()
	if err != nil {
		return err
	}
	runtime := os.Getenv("BEE_RUNTIME")
	if runtime == "" {
		runtime = filepath.Join(repo, ".wippy/bin/bee-wippy")
	}
	runtime, err = filepath.Abs(runtime)
	if err != nil {
		return err
	}
	if info, statErr := os.Stat(runtime); statErr != nil || info.IsDir() {
		return fmt.Errorf("candidate runtime %q is unavailable", runtime)
	}
	folder, err := os.MkdirTemp("", "bee-hub-migration-service-")
	if err != nil {
		return err
	}
	succeeded := false
	defer func() {
		if succeeded {
			_ = os.RemoveAll(folder)
		} else {
			fmt.Fprintln(os.Stderr, "Hub migration service fixture preserved:", folder)
		}
	}()
	binary := filepath.Join(folder, "hub-fixture")
	if err := buildFixtureBinary(repo, binary); err != nil {
		return err
	}
	source, err := os.ReadFile(filepath.Join(repo, "tests/fixtures/hub_migration_service/migration.lua"))
	if err != nil {
		return err
	}
	second := strings.ReplaceAll(string(source), "fixture_payload", "fixture_second")
	second = strings.Replace(second,
		"    local tx = assert(db:begin())", "    local gate, problem = db:query(\"SELECT ready FROM fixture_gate\")\n    if not gate then db:release(); error(tostring(problem)) end\n    local tx = assert(db:begin())", 1)
	packages := map[string][]wapp.Entry{
		"acme/app@1.0.0":     {packageEntryFor("acme.app", "definition", "ns.definition", nil, nil), packageEntryFor("acme.app", "storage", "ns.dependency", map[string]any{"component": "acme/storage", "version": "1.0.0"}, nil)},
		"acme/storage@1.0.0": {packageEntryFor("acme.storage", "definition", "ns.definition", nil, nil), packageEntryFor("acme.storage", "first", "function.lua", map[string]any{"source": string(source), "method": "run", "modules": []string{"sql"}}, map[string]any{"type": "migration", "target_db": "probe:db", "timestamp": "2026-09-12T12:00:00Z"})},
		"acme/app@1.1.0":     {packageEntryFor("acme.app", "definition", "ns.definition", nil, nil), packageEntryFor("acme.app", "storage", "ns.dependency", map[string]any{"component": "acme/storage", "version": "1.1.0"}, nil)},
		"acme/storage@1.1.0": {packageEntryFor("acme.storage", "definition", "ns.definition", nil, nil), packageEntryFor("acme.storage", "first", "function.lua", map[string]any{"source": string(source), "method": "run", "modules": []string{"sql"}}, map[string]any{"type": "migration", "target_db": "probe:db", "timestamp": "2026-09-12T12:00:00Z"}), packageEntryFor("acme.storage", "second", "function.lua", map[string]any{"source": second, "method": "run", "modules": []string{"sql"}}, map[string]any{"type": "migration", "target_db": "probe:db", "timestamp": "2026-09-12T13:00:00Z"})},
		"acme/app@1.2.0":     {packageEntryFor("acme.app", "definition", "ns.definition", nil, nil), packageEntryFor("acme.app", "storage", "ns.dependency", map[string]any{"component": "acme/storage", "version": "1.2.0"}, nil)},
		"acme/storage@1.2.0": {packageEntryFor("acme.storage", "definition", "ns.definition", nil, nil), packageEntryFor("acme.storage", "target_db", "ns.requirement", map[string]any{"default": "raw:default", "targets": []any{map[string]any{"entry": "acme.storage:first", "path": ".meta.target_db"}}}, nil), packageEntryFor("acme.storage", "first", "function.lua", map[string]any{"source": string(source), "method": "run", "modules": []string{"sql"}}, map[string]any{"type": "migration", "target_db": "raw:database", "timestamp": "2026-09-12T12:00:00Z"})},
	}
	descriptions := filepath.Join(folder, "packages.json")
	encoded, err := json.Marshal(packages)
	if err != nil {
		return err
	}
	if err := os.WriteFile(descriptions, encoded, 0600); err != nil {
		return err
	}
	server, serverLog, hubURL, err := startFixtureServer(binary, descriptions, filepath.Join(folder, "server.log"))
	if err != nil {
		return err
	}
	defer func() {
		_ = syscall.Kill(-server.Process.Pid, syscall.SIGKILL)
		_ = server.Wait()
		_ = serverLog.Close()
	}()
	for _, mode := range []string{"absent", "applied", "denied", "crash", "partial", "tamper", "linked"} {
		workspace := filepath.Join(folder, mode)
		if err := os.Mkdir(workspace, 0700); err != nil {
			return err
		}
		if err := prepareFixture(workspace, repo); err != nil {
			return err
		}
		if err := os.Mkdir(filepath.Join(workspace, ".wippy"), 0700); err != nil {
			return err
		}
		if err := copyServiceFile(filepath.Join(repo, "tests/fixtures/hub_migration_service/probe.lua"), filepath.Join(workspace, "repo-probe.lua")); err != nil {
			return err
		}
		if err := runMode(runtime, workspace, hubURL, mode); err != nil {
			return err
		}
	}
	succeeded = true
	fmt.Println("Hub migration service: real up/replay, committed-schema SIGKILL/restart, partial failure/retry, changed-definition refusal, requirement-linked target, orphan removal block, absent ledger and denied database grant pass")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
