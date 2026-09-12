// SPDX-License-Identifier: MIT
// Real SQL/ledger compatibility with the pinned public migration libraries.
// The artifact supplies unchanged libraries to a disposable composition, not
// a production dependency. Its bootloader and package dependencies are not
// activated.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/wippyai/wapp"
	"gopkg.in/yaml.v3"
)

const artifactDigest = "55834821cd2832f8582a52e98772810ba3bdfe91d4967262d3d69e6e9c2b2879"

func repositoryRoot() (string, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	if filepath.Base(cwd) == "native" {
		return filepath.Dir(cwd), nil
	}
	return cwd, nil
}

func runRuntime(runtime, dir string, env []string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir = dir
	cmd.Env = env
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

func sqlLines(database, query string) ([]string, error) {
	result := exec.Command("sqlite3", "-readonly", "-batch", "-noheader", "-separator", "\x1f", database, query)
	output, err := result.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("sqlite3: %w: %s", err, strings.TrimSpace(string(output)))
	}
	text := strings.TrimSpace(string(output))
	if text == "" {
		return nil, nil
	}
	return strings.Split(text, "\n"), nil
}

func fixtureEnvironment(folder string) []string {
	return []string{
		"HOME=" + filepath.Join(folder, "home"),
		"XDG_CONFIG_HOME=" + filepath.Join(folder, "config"),
		"XDG_DATA_HOME=" + filepath.Join(folder, "data"),
		"XDG_STATE_HOME=" + filepath.Join(folder, "state"),
		"PATH=/usr/bin:/bin",
		"GOMAXPROCS=2",
	}
}

func copyRunnerFixture(root, repo string) error {
	if err := os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join(repo, "tests/fixtures/hub_migration_runner"))); err != nil {
		return fmt.Errorf("copy migration runner fixture: %w", err)
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		if err := copyFile(filepath.Join(repo, name), filepath.Join(root, name)); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Join(root, ".wippy"), 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, "src/hub"), 0700); err != nil {
		return err
	}
	for _, name := range []string{"migrations.lua", "migration_runner.lua"} {
		if err := copyFile(filepath.Join(repo, "src/hub", name), filepath.Join(root, "src/hub", name)); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("read %s: %w", source, err)
	}
	if err := os.WriteFile(destination, data, 0600); err != nil {
		return fmt.Errorf("write %s: %w", destination, err)
	}
	return nil
}

func projectLibraries(root string, entries []wapp.Entry) error {
	selected := map[string]bool{"core": true, "migration": true, "registry": true, "repository": true, "runner": true}
	libraries := filepath.Join(root, "src/wippy_migration")
	if err := os.MkdirAll(libraries, 0700); err != nil {
		return err
	}
	manifest := map[string]any{"version": "1.0", "namespace": "wippy.migration", "entries": []any{}}
	projected := manifest["entries"].([]any)
	projectedNames := make(map[string]bool, len(selected))
	for _, entry := range entries {
		if entry.ID.Namespace != "wippy.migration" || !selected[entry.ID.Name] {
			continue
		}
		if projectedNames[entry.ID.Name] {
			return fmt.Errorf("duplicate wippy.migration:%s entry", entry.ID.Name)
		}
		if entry.Kind != "library.lua" {
			return fmt.Errorf("wippy.migration:%s has kind %q", entry.ID.Name, entry.Kind)
		}
		data, ok := entry.Data.(map[string]any)
		if !ok {
			return fmt.Errorf("wippy.migration:%s has invalid data", entry.ID.Name)
		}
		source, ok := data["source"].(string)
		if !ok || source == "" {
			return fmt.Errorf("wippy.migration:%s has no source", entry.ID.Name)
		}
		projectedNames[entry.ID.Name] = true
		if err := os.WriteFile(filepath.Join(libraries, entry.ID.Name+".lua"), []byte(source), 0600); err != nil {
			return err
		}
		meta := entry.Meta
		if meta == nil {
			meta = map[string]any{}
		}
		projectedEntry := map[string]any{"name": entry.ID.Name, "kind": "library.lua", "meta": meta}
		for field, value := range data {
			if field != "source" {
				projectedEntry[field] = value
			}
		}
		projectedEntry["source"] = "file://" + entry.ID.Name + ".lua"
		projected = append(projected, projectedEntry)
	}
	if len(projected) != len(selected) {
		return fmt.Errorf("pinned artifact projected %d migration libraries, want %d", len(projected), len(selected))
	}
	manifest["entries"] = projected
	encoded, err := yaml.Marshal(manifest)
	if err != nil {
		return fmt.Errorf("encode migration manifest: %w", err)
	}
	return os.WriteFile(filepath.Join(libraries, "_index.yaml"), encoded, 0600)
}

func decodeEntries(repo, artifact string) ([]wapp.Entry, error) {
	cmd := exec.Command("go", "run", "-mod=readonly", filepath.Join(repo, "tests/hub_migration_entries.go"), artifact)
	cmd.Dir = filepath.Join(repo, "native")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("decode migration artifact: %w\n%s", err, output)
	}
	var entries []wapp.Entry
	if err := json.Unmarshal(output, &entries); err != nil {
		return nil, fmt.Errorf("decode migration entries JSON: %w", err)
	}
	return entries, nil
}

func checkRunnerDatabases(folder string) error {
	database := filepath.Join(folder, ".wippy/probe.db")
	rows, err := sqlLines(database, "SELECT phase || char(31) || users_table || char(31) || audit_table || char(31) || excluded_table || char(31) || first_ledger || char(31) || second_ledger || char(31) || excluded_ledger FROM probe_acceptance_evidence ORDER BY phase")
	if err != nil {
		return err
	}
	want := []string{"binding_down\x1f0\x1f0\x1f0\x1f0\x1f0\x1f0", "binding_up\x1f1\x1f1\x1f0\x1f1\x1f1\x1f0", "public_down\x1f0\x1f0\x1f0\x1f0\x1f0\x1f0", "public_repeat\x1f1\x1f1\x1f0\x1f1\x1f1\x1f0", "public_up\x1f1\x1f1\x1f0\x1f1\x1f1\x1f0"}
	// The expected rows are deliberately compared as parsed fields so this
	// remains clear if sqlite changes its output escaping.
	if len(rows) != 5 {
		return fmt.Errorf("unexpected public evidence rows: %v", rows)
	}
	for i, row := range rows {
		fields := strings.Split(row, "\x1f")
		if len(fields) != 7 || fields[1] != "0" && fields[1] != "1" {
			return fmt.Errorf("invalid public evidence row %q", row)
		}
		if row != want[i] {
			return fmt.Errorf("public evidence row %d = %q, want %q", i, row, want[i])
		}
	}
	if rows, err = sqlLines(database, "SELECT id FROM _migrations"); err != nil {
		return err
	} else if len(rows) != 0 {
		return fmt.Errorf("migration ledger was not cleared: %v", rows)
	}
	if rows, err = sqlLines(database, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"); err != nil {
		return err
	} else if strings.Join(rows, ",") != "_migrations,probe_acceptance_evidence" {
		return fmt.Errorf("public tables = %v", rows)
	}
	return nil
}

func checkNegativeDatabases(folder string) error {
	evidence := filepath.Join(folder, ".wippy/evidence.db")
	rows, err := sqlLines(evidence, "SELECT phase || char(31) || value || char(31) || problem FROM negative_evidence ORDER BY phase")
	if err != nil {
		return err
	}
	want := map[string]string{
		"absent_ledger":        "false\x1fnil",
		"missing_db_grant":     "false\x1fdatabase grant",
		"missing_db_attempt":   "true\x1fdatabase",
		"missing_func_grant":   "false\x1ffunction grant",
		"missing_func_attempt": "true\x1ffunction grant",
	}
	if len(rows) != len(want) {
		return fmt.Errorf("negative evidence rows = %v", rows)
	}
	for _, row := range rows {
		fields := strings.SplitN(row, "\x1f", 3)
		expected, known := want[fields[0]]
		if len(fields) != 3 || !known || fields[1] != strings.SplitN(expected, "\x1f", 2)[0] || !strings.Contains(fields[2], strings.SplitN(expected, "\x1f", 2)[1]) {
			return fmt.Errorf("unexpected negative evidence row %q", row)
		}
	}
	if rows, err = sqlLines(filepath.Join(folder, ".wippy/negative.db"), "SELECT name FROM sqlite_master WHERE type='table'"); err != nil {
		return err
	} else if len(rows) != 0 {
		return fmt.Errorf("negative database changed: %v", rows)
	}
	return nil
}

func run() error {
	flag.Parse()
	args := flag.Args()
	if len(args) != 1 {
		return fmt.Errorf("usage: hub_migration_runner.go ARTIFACT")
	}
	repo, err := repositoryRoot()
	if err != nil {
		return err
	}
	runtimePath := os.Getenv("BEE_RUNTIME")
	if runtimePath == "" {
		runtimePath = filepath.Join(repo, ".wippy/bin/bee-wippy")
	}
	runtimePath, err = filepath.Abs(runtimePath)
	if err != nil {
		return err
	}
	artifact, err := filepath.Abs(args[0])
	if err != nil {
		return err
	}
	data, err := os.ReadFile(artifact)
	if err != nil {
		return fmt.Errorf("read artifact: %w", err)
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != artifactDigest {
		return fmt.Errorf("expected pinned migration artifact digest %s", artifactDigest)
	}
	entries, err := decodeEntries(repo, artifact)
	if err != nil {
		return err
	}
	folder, err := os.MkdirTemp("", "bee-hub-migration-")
	if err != nil {
		return err
	}
	keep := true
	defer func() {
		if !keep {
			_ = os.RemoveAll(folder)
		} else {
			fmt.Fprintln(os.Stderr, "Migration fixture preserved:", folder)
		}
	}()
	if err := copyRunnerFixture(folder, repo); err != nil {
		return err
	}
	if err := projectLibraries(folder, entries); err != nil {
		return err
	}
	env := fixtureEnvironment(folder)
	output, err := runRuntime(runtimePath, folder, env, "run", "-x", "probe:run")
	_ = os.WriteFile(filepath.Join(folder, "runtime.log"), output, 0600)
	if err != nil {
		return fmt.Errorf("migration probe exited: %w\n%s", err, output)
	}
	if err := checkRunnerDatabases(folder); err != nil {
		return err
	}
	output, err = runRuntime(runtimePath, folder, env, "run", "-x", "probe:negative_run")
	_ = os.WriteFile(filepath.Join(folder, "negative-runtime.log"), output, 0600)
	if err != nil {
		return fmt.Errorf("negative probe exited: %w\n%s", err, output)
	}
	if err := checkNegativeDatabases(folder); err != nil {
		return err
	}
	keep = false
	fmt.Println("Hub migration runner: public DSL and Bee binding agree on SQLite up/repeat/down; excluded ID stays untouched; absent ledger and denied grants have no schema effects")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
