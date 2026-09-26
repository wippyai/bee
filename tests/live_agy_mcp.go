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
	author := flag.Bool("author", false, "prove Gemini authors a frozen research artifact through MCP")
	proposalPath := flag.String("proposal", "", "prior authored artifact to repair through MCP")
	reviewPath := flag.String("review", "", "review feedback for the prior authored artifact")
	flag.Parse()
	if (*proposalPath != "" || *reviewPath != "") && (!*author || *proposalPath == "" || *reviewPath == "") {
		return fmt.Errorf("proposal and review must be supplied together with author")
	}
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
	if err = os.CopyFS(filepath.Join(root, "modules"), os.DirFS(filepath.Join(repo, "modules"))); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		if err = copyFile(filepath.Join(root, name), filepath.Join(repo, name)); err != nil {
			return err
		}
	}
	fixture := "live_agy_mcp"
	if *author {
		fixture = "research_author"
	}
	if err = os.CopyFS(filepath.Join(root, "src/research_probe"), os.DirFS(filepath.Join(repo, "tests/fixtures", fixture))); err != nil {
		return err
	}
	if *author {
		// Tool metadata grants nothing. The experiment host separately admits
		// this exact operation to the endpoint, as well as its per-tool scope.
		gatewayPath := filepath.Join(root, "modules/gateway/src/api/_index.yaml")
		gatewayBytes, readErr := os.ReadFile(gatewayPath)
		if readErr != nil {
			return readErr
		}
		var gateway map[string]interface{}
		if err = yaml.Unmarshal(gatewayBytes, &gateway); err != nil {
			return err
		}
		admitted := false
		for _, raw := range gateway["entries"].([]interface{}) {
			entry := raw.(map[string]interface{})
			if entry["name"] == "mcp_http" {
				security := entry["security"].(map[string]interface{})
				security["policies"] = append(security["policies"].([]interface{}), "bee.research.probe:docs_policy")
				admitted = true
			}
		}
		if !admitted {
			return fmt.Errorf("MCP endpoint entry missing")
		}
		gatewayBytes, err = yaml.Marshal(gateway)
		if err != nil {
			return err
		}
		if err = os.WriteFile(gatewayPath, gatewayBytes, 0600); err != nil {
			return err
		}
		material := map[string]string{}
		for topic, relative := range map[string]string{
			"source": "modules/threads/src/records/canonical.lua", "corpus": "tests/fixtures/performance_research/corpus.lua",
			"authoring": "tests/fixtures/research_author/AUTHORING.md", "application": "modules/threads-timeline/src/app.lua",
			"model": "modules/threads-timeline/src/model.lua", "view": "modules/threads-timeline/src/view.lua",
		} {
			data, readErr := os.ReadFile(filepath.Join(repo, relative))
			if readErr != nil {
				return readErr
			}
			material[topic] = string(data)
		}
		material["proposal"], material["review"] = "", ""
		if *proposalPath != "" {
			for topic, path := range map[string]string{"proposal": *proposalPath, "review": *reviewPath} {
				data, readErr := os.ReadFile(path)
				if readErr != nil {
					return readErr
				}
				if len(data) == 0 || len(data) > 262144 {
					return fmt.Errorf("%s exceeds review input bounds", topic)
				}
				material[topic] = string(data)
			}
		}
		document := map[string]interface{}{"version": "1.0", "namespace": "bee.research.probe", "entries": []interface{}{
			map[string]interface{}{"name": "material", "kind": "registry.entry", "data": material},
		}}
		data, marshalErr := yaml.Marshal(document)
		if marshalErr != nil {
			return marshalErr
		}
		if err = os.MkdirAll(filepath.Join(root, "src/research_material"), 0700); err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(root, "src/research_material/_index.yaml"), data, 0600); err != nil {
			return err
		}
	}
	host := filepath.Join(root, "src/research_host")
	if err = os.MkdirAll(host, 0700); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(host, "_index.yaml"), []byte("version: '1.0'\nnamespace: bee.harness.host\nentries:\n- name: environment\n  kind: env.storage.os\n  lifecycle: {auto_start: true}\n"), 0600); err != nil {
		return err
	}
	if err = setVariable(root, "modules/driver-agy/src/_index.yaml", "executable", "BEE_RESEARCH_AGY_EXECUTABLE"); err != nil {
		return err
	}
	if err = setVariable(root, "src/env/_index.yaml", "machine_home", "BEE_RESEARCH_USER_HOME"); err != nil {
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
	runDeadline := 4 * time.Minute
	if *author {
		runDeadline = 6 * time.Minute
	}
	if err = run(root, runtime, environment, "run", runDeadline, "run", "research-live-probe", "--set", "registry.history_path="+filepath.Join(root, "registry.db")); err != nil {
		return err
	}
	if *author {
		log, readErr := os.ReadFile(filepath.Join(root, "run.log"))
		if readErr != nil {
			return readErr
		}
		var authored map[string]interface{}
		for _, line := range strings.Split(string(log), "\n") {
			if strings.HasPrefix(line, "RESEARCH_AUTHORED ") {
				if authored != nil {
					return fmt.Errorf("duplicate authored artifact")
				}
				if err = json.Unmarshal([]byte(strings.TrimPrefix(line, "RESEARCH_AUTHORED ")), &authored); err != nil {
					return err
				}
			}
		}
		if authored == nil {
			return fmt.Errorf("missing verified authored artifact: %s", root)
		}
		data, marshalErr := json.MarshalIndent(authored, "", "  ")
		if marshalErr != nil {
			return marshalErr
		}
		if err = os.WriteFile(filepath.Join(root, "authored.json"), data, 0600); err != nil {
			return err
		}
		// Compile the proposed entries in a separate review tree. They are not
		// added to the running host or applied to its live registry overlay.
		review := filepath.Join(root, "review")
		if err = os.CopyFS(filepath.Join(review, "src"), os.DirFS(filepath.Join(root, "src"))); err != nil {
			return err
		}
		if err = os.CopyFS(filepath.Join(review, "modules"), os.DirFS(filepath.Join(root, "modules"))); err != nil {
			return err
		}
		for _, name := range []string{".wippy.yaml", "wippy.lock"} {
			if err = copyFile(filepath.Join(review, name), filepath.Join(root, name)); err != nil {
				return err
			}
		}
		entries, ok := authored["entries"].([]interface{})
		if !ok || len(entries) == 0 {
			return fmt.Errorf("authored entries missing")
		}
		for _, raw := range entries {
			entry, ok := raw.(map[string]interface{})
			if !ok {
				return fmt.Errorf("invalid authored entry")
			}
			id, ok := entry["id"].(string)
			if !ok || !strings.HasPrefix(id, "bee.research.demo:") {
				return fmt.Errorf("foreign authored entry")
			}
			entry["name"] = strings.TrimPrefix(id, "bee.research.demo:")
			delete(entry, "id")
		}
		proposed, marshalErr := yaml.Marshal(map[string]interface{}{"version": "1.0", "namespace": "bee.research.demo", "entries": entries})
		if marshalErr != nil {
			return marshalErr
		}
		if err = os.MkdirAll(filepath.Join(review, "src/research_candidate"), 0700); err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(review, "src/research_candidate/_index.yaml"), proposed, 0600); err != nil {
			return err
		}
		if err = run(review, runtime, environment, "lint", 3*time.Minute, "lint"); err != nil {
			return err
		}
		fmt.Println("RESEARCH_AUTHOR_PASS: real Gemini authored and froze candidate/dashboard via MCP; typed lint passed; not applied")
		return nil
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
