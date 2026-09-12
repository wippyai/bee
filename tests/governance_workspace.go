// SPDX-License-Identifier: MIT
// Verify durable governance authoring through two real runtime boots.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const defaultRuntime = "/tmp/bee-runtime-native-recovery-20260911"

const syncIndex = `version: '1.0'
namespace: bee.sync
entries:
- name: definition
  kind: ns.definition
  module: sync
  readme: file://README.md
- name: bounds
  kind: library.lua
  source: file://bounds.lua
- name: canonical
  kind: library.lua
  source: file://canonical.lua
  imports:
    bounds: bee.sync:bounds
`

const recordsIndex = `version: '1.0'
namespace: bee.threads.records
entries:
- name: bounds
  kind: library.lua
  source: file://bounds.lua
`

func runCommand(ctx context.Context, directory, runtime string, environment []string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = directory
	command.Env = append(os.Environ(), environment...)
	return command.CombinedOutput()
}

func copyTree(destination, source string) error {
	return os.CopyFS(destination, os.DirFS(source))
}

func copyFile(destination, source string) error {
	from, err := os.Open(source)
	if err != nil {
		return err
	}
	defer from.Close()
	to, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer to.Close()
	_, err = io.Copy(to, from)
	return err
}

func setup(root string) error {
	for _, name := range []string{"governance", "sync", "persist"} {
		if err := copyTree(filepath.Join(root, "src", name), filepath.Join("src", name)); err != nil {
			return fmt.Errorf("copy %s source: %w", name, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "src", "sync", "_index.yaml"), []byte(syncIndex), 0600); err != nil {
		return fmt.Errorf("write bounded sync composition: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(root, "src", "records"), 0700); err != nil {
		return fmt.Errorf("create records composition: %w", err)
	}
	if err := copyFile(filepath.Join(root, "src", "records", "bounds.lua"), "src/threads/records/bounds.lua"); err != nil {
		return fmt.Errorf("copy records bounds: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "records", "_index.yaml"), []byte(recordsIndex), 0600); err != nil {
		return fmt.Errorf("write records composition: %w", err)
	}
	if err := copyTree(filepath.Join(root, "src", "governance_workspace_probe"), "tests/fixtures/governance_workspace"); err != nil {
		return fmt.Errorf("copy governance fixture: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		return fmt.Errorf("write runtime lock: %w", err)
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return fmt.Errorf("write bounded shutdown config: %w", err)
	}
	return nil
}

func boot(runtime, root, phase string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	database := filepath.Join(root, "governance.db")
	output, err := runCommand(ctx, root, runtime, []string{
		"BEE_GOVERNANCE_DB=" + database,
		"GOMAXPROCS=2",
	}, "run", "--verbose", "--host", "bee.governance_workspace_probe:workers", "--", "governance-workspace-probe", phase)
	marker := "GOVERNANCE_WORKSPACE_" + strings.ToUpper(phase) + "_BOOT_PASS"
	if err != nil {
		return fmt.Errorf("%s boot: %w\n%s", phase, err, output)
	}
	if !strings.Contains(string(output), marker) {
		return fmt.Errorf("%s boot omitted %s\n%s", phase, marker, output)
	}
	fmt.Println(marker)
	return nil
}

func sqlite(root, query string) (string, error) {
	output, err := exec.Command("sqlite3", "-batch", "-noheader", filepath.Join(root, "governance.db"), query).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("inspect disposable governance database: %w\n%s", err, output)
	}
	return strings.TrimSpace(string(output)), nil
}

func migrationLedger(root string) (string, error) {
	ledger, err := sqlite(root, "SELECT id || '|' || name || '|' || checksum || '|' || applied_at FROM bee_governance_migrations ORDER BY id;")
	if err != nil {
		return "", err
	}
	parts := strings.Split(ledger, "|")
	if len(parts) != 4 || parts[0] != "1" || parts[1] != "governance_workspace_staging" || len(parts[2]) != 64 || parts[3] == "" {
		return "", fmt.Errorf("unexpected governance migration ledger: %q", ledger)
	}
	return ledger, nil
}

func run() error {
	runtimeFlag := flag.String("runtime", defaultRuntime, "candidate Wippy runtime")
	flag.Parse()
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		return fmt.Errorf("resolve runtime: %w", err)
	}
	if info, err := os.Stat(runtime); err != nil || info.IsDir() {
		return fmt.Errorf("candidate runtime %q is unavailable", runtime)
	}
	root, err := os.MkdirTemp("", "bee-governance-workspace-")
	if err != nil {
		return fmt.Errorf("create disposable workspace: %w", err)
	}
	defer os.RemoveAll(root)
	if err := setup(root); err != nil {
		return err
	}

	lintContext, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	lint, err := runCommand(lintContext, root, runtime, nil, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true")
	if err != nil {
		return fmt.Errorf("strict fixture lint: %w\n%s", err, lint)
	}

	if err := boot(runtime, root, "first"); err != nil {
		return err
	}
	before, err := migrationLedger(root)
	if err != nil {
		return err
	}
	if err := boot(runtime, root, "second"); err != nil {
		return err
	}
	after, err := migrationLedger(root)
	if err != nil {
		return err
	}
	if after != before {
		return fmt.Errorf("governance migration ledger changed across restart: %q -> %q", before, after)
	}
	content, err := sqlite(root, "SELECT content_base64 FROM bee_governance_snapshot_files ORDER BY path;")
	if err != nil {
		return err
	}
	if content != "AP9hc3NldA==" {
		return fmt.Errorf("frozen binary content changed: %q", content)
	}
	receipts, err := sqlite(root, "SELECT COUNT(*) FROM bee_governance_receipts;")
	if err != nil {
		return err
	}
	if receipts != "4" {
		return fmt.Errorf("receipt replay changed durable receipt count: %q", receipts)
	}
	fmt.Println("Governance authoring: two actual boots retained frozen binary bytes, exact receipts and author denial with an unchanged migration ledger")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
