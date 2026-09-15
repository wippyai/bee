// SPDX-License-Identifier: MIT
// Explicit live-provider acceptance; intentionally outside the default check.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

func copyFile(dst, src string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(dst), 0700); err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0600)
}

func setVariable(root, relative, name, variable string) error {
	path := filepath.Join(root, relative)
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var document map[string]interface{}
	if err = yaml.Unmarshal(data, &document); err != nil {
		return err
	}
	entries, ok := document["entries"].([]interface{})
	if !ok {
		return fmt.Errorf("%s: entries missing", relative)
	}
	found := false
	for _, raw := range entries {
		entry, ok := raw.(map[string]interface{})
		if ok && entry["name"] == name {
			entry["variable"] = variable
			found = true
		}
	}
	if !found {
		return fmt.Errorf("%s: missing %s", relative, name)
	}
	data, err = yaml.Marshal(document)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

func run(root, runtime string, environment []string, label string, deadline time.Duration, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir, cmd.Env = root, environment
	// Give the runtime time to cancel its managed carrier before a hard stop.
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 15 * time.Second
	log, err := os.OpenFile(filepath.Join(root, label+".log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd.Stdout, cmd.Stderr = log, log
	if err = cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w (private evidence: %s)", label, err, root)
	}
	return nil
}

func check() error {
	source := flag.String("root", "..", "Bee source root")
	selectedRuntime := flag.String("runtime", "", "native runtime executable")
	selectedAgy := flag.String("agy", "agy", "installed Agy executable")
	lintOnly := flag.Bool("lint-only", false, "stage and lint without provider inference")
	flag.Parse()
	repo, err := filepath.Abs(*source)
	if err != nil {
		return err
	}
	runtime := *selectedRuntime
	if runtime == "" {
		runtime = filepath.Join(repo, ".wippy/bin/bee-wippy")
	}
	runtime, err = filepath.Abs(runtime)
	if err != nil {
		return err
	}
	agy, err := exec.LookPath(*selectedAgy)
	if err != nil {
		return err
	}
	agy, err = filepath.Abs(agy)
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "bee-live-agy-mcp-")
	if err != nil {
		return err
	}
	// Retain evidence privately, including after failure; never print credentials.
	fmt.Println("Private evidence:", root)
	if err = os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join(repo, "src"))); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		if err = copyFile(filepath.Join(root, name), filepath.Join(repo, name)); err != nil {
			return err
		}
	}
	if err = os.CopyFS(filepath.Join(root, "src/research_probe"), os.DirFS(filepath.Join(repo, "tests/fixtures/live_agy_mcp"))); err != nil {
		return err
	}
	host := filepath.Join(root, "src/research_host")
	if err = os.MkdirAll(host, 0700); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(host, "_index.yaml"), []byte("version: '1.0'\nnamespace: bee.harness.host\nentries:\n- name: environment\n  kind: env.storage.os\n  lifecycle: {auto_start: true}\n"), 0600); err != nil {
		return err
	}
	if err = setVariable(root, "src/driver/agy/_index.yaml", "executable", "BEE_RESEARCH_AGY_EXECUTABLE"); err != nil {
		return err
	}
	if err = setVariable(root, "src/environment/_index.yaml", "machine_home", "BEE_RESEARCH_USER_HOME"); err != nil {
		return err
	}
	overrides := map[string]string{"BEE_RESEARCH_AGY_EXECUTABLE": agy, "BEE_RESEARCH_USER_HOME": home}
	for _, name := range []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance", "sync"} {
		overrides["BEE_"+strings.ToUpper(name)+"_DB"] = filepath.Join(root, name+".db")
	}
	environment := []string{}
	for _, item := range os.Environ() {
		key, _, _ := strings.Cut(item, "=")
		if _, replaced := overrides[key]; !replaced {
			environment = append(environment, item)
		}
	}
	for key, value := range overrides {
		environment = append(environment, key+"="+value)
	}
	if err = run(root, runtime, environment, "lint", 3*time.Minute, "lint"); err != nil {
		return err
	}
	if *lintOnly {
		fmt.Println("Live Agy fixture lint passed; no inference performed")
		return nil
	}
	if err = run(root, runtime, environment, "run", 4*time.Minute, "run", "research-live-probe", "--set", "registry.history_path="+filepath.Join(root, "registry.db")); err != nil {
		return err
	}
	evidence, err := json.MarshalIndent(map[string]interface{}{"passed": true, "proof": "real Gemini requested MCP access, received test-operator inbox approval, selected two traits and committed the exact bound thread message", "runtime": runtime, "agy": agy}, "", "  ")
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(root, "evidence.json"), evidence, 0600); err != nil {
		return err
	}
	fmt.Println("LIVE_AGY_MCP_PASS: agent access request, test-operator inbox approval, bound thread message, traits and context")
	return nil
}
func main() {
	if err := check(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
