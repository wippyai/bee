// SPDX-License-Identifier: MIT
// Bounded Bee acceptance fixture for research delivery.
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

func run(root, runtime string, environment []string, label string, deadline time.Duration, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir, cmd.Env = root, environment
	// Allow runtime to cancel gracefully before hard termination.
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

func reviewArtifact(root, runtime string, environment []string, entries []interface{}) error {
	review := filepath.Join(root, "review")
	if err := os.CopyFS(filepath.Join(review, "src"), os.DirFS(filepath.Join(root, "src"))); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		if err := copyFile(filepath.Join(review, name), filepath.Join(root, name)); err != nil {
			return err
		}
	}
	candidateEntries := make([]interface{}, 0, len(entries))
	for _, raw := range entries {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			return fmt.Errorf("invalid entry: expected map")
		}
		copyEntry := make(map[string]interface{}, len(entry))
		for k, v := range entry {
			copyEntry[k] = v
		}
		id, ok := copyEntry["id"].(string)
		if !ok || !strings.HasPrefix(id, "bee.research.demo:") {
			return fmt.Errorf("foreign entry: %v", id)
		}
		copyEntry["name"] = strings.TrimPrefix(id, "bee.research.demo:")
		delete(copyEntry, "id")
		candidateEntries = append(candidateEntries, copyEntry)
	}
	proposed, err := yaml.Marshal(map[string]interface{}{
		"version":   "1.0",
		"namespace": "bee.research.demo",
		"entries":   candidateEntries,
	})
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Join(review, "src/research_candidate"), 0700); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(review, "src/research_candidate/_index.yaml"), proposed, 0600); err != nil {
		return err
	}
	return run(review, runtime, environment, "artifact_lint", 3*time.Minute, "lint")
}

func check() error {
	source := flag.String("root", "..", "Bee source root")
	selectedRuntime := flag.String("runtime", "", "native runtime executable")
	artifactPath := flag.String("artifact", "", "path to authored artifact json")
	lintOnly := flag.Bool("lint-only", false, "stage and lint without applying artifact")
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

	var artifactBytes []byte
	var artifactDoc map[string]interface{}
	var entries []interface{}
	var artifactDigest string

	if *artifactPath != "" {
		cleanedPath, cleanErr := filepath.Abs(*artifactPath)
		if cleanErr != nil {
			return cleanErr
		}
		artifactBytes, err = os.ReadFile(cleanedPath)
		if err != nil {
			return fmt.Errorf("failed to read artifact: %w", err)
		}
		if err = json.Unmarshal(artifactBytes, &artifactDoc); err != nil {
			return fmt.Errorf("invalid artifact json: %w", err)
		}
		rawEntries, ok := artifactDoc["entries"].([]interface{})
		if !ok || len(rawEntries) == 0 {
			return fmt.Errorf("artifact missing entries array")
		}
		entries = rawEntries
		rawDigest, ok := artifactDoc["artifact_digest"].(string)
		if !ok || len(rawDigest) != 64 {
			return fmt.Errorf("artifact missing or invalid artifact_digest")
		}
		artifactDigest = rawDigest

		for i, raw := range entries {
			entry, ok := raw.(map[string]interface{})
			if !ok {
				return fmt.Errorf("entry %d is not an object", i)
			}
			id, ok := entry["id"].(string)
			if !ok || !strings.HasPrefix(id, "bee.research.demo:") {
				return fmt.Errorf("entry %d has invalid or foreign id: %v", i, entry["id"])
			}
			kind, ok := entry["kind"].(string)
			if !ok || (kind != "process.lua" && kind != "library.lua") {
				return fmt.Errorf("entry %s has unadmitted kind: %v", id, entry["kind"])
			}
			configuration, ok := entry["data"].(map[string]interface{})
			if !ok {
				return fmt.Errorf("entry %s has no native configuration data", id)
			}
			sourceText, ok := configuration["source"].(string)
			if !ok || len(sourceText) == 0 {
				return fmt.Errorf("entry %s has missing or empty source", id)
			}
		}
	}

	root, err := os.MkdirTemp("", "bee-research-delivery-")
	if err != nil {
		return err
	}
	fmt.Println("Private evidence:", root)

	if err = os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join(repo, "src"))); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock"} {
		if err = copyFile(filepath.Join(root, name), filepath.Join(repo, name)); err != nil {
			return err
		}
	}

	fixtureDir := filepath.Join(repo, "tests/fixtures/research_delivery")
	if err = os.CopyFS(filepath.Join(root, "src/research_delivery"), os.DirFS(fixtureDir)); err != nil {
		return err
	}

	if artifactDoc != nil {
		indexPath := filepath.Join(root, "src/research_delivery/_index.yaml")
		indexBytes, readErr := os.ReadFile(indexPath)
		if readErr != nil {
			return readErr
		}
		var indexDoc map[string]interface{}
		if err = yaml.Unmarshal(indexBytes, &indexDoc); err != nil {
			return err
		}
		entriesList, ok := indexDoc["entries"].([]interface{})
		if !ok {
			return fmt.Errorf("fixture _index.yaml missing entries")
		}
		for _, raw := range entriesList {
			entry, ok := raw.(map[string]interface{})
			if ok && entry["name"] == "artifact_input" {
				entry["data"] = map[string]interface{}{
					"artifact_digest": artifactDigest,
					"raw_json":        string(artifactBytes),
				}
			}
		}
		updatedIndex, marshalErr := yaml.Marshal(indexDoc)
		if marshalErr != nil {
			return marshalErr
		}
		if err = os.WriteFile(indexPath, updatedIndex, 0600); err != nil {
			return err
		}
	}

	overrides := map[string]string{}
	// The native executable normally supplies these host bindings. This direct
	// runtime fixture supplies inert existing paths; it launches no providers.
	for _, name := range []string{"self", "agy", "claude", "codex", "grok"} {
		overrides[name] = runtime
	}
	overrides["home"] = root
	overrides["ANTHROPIC_API_KEY"] = "fixture-only"
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

	if len(entries) > 0 {
		if err = reviewArtifact(root, runtime, environment, entries); err != nil {
			return fmt.Errorf("artifact review lint: %w", err)
		}
	}

	if *lintOnly {
		fmt.Println("RESEARCH_DELIVERY_LINT_PASS: fixture and supplied artifact lint passed; no apply")
		return nil
	}

	if *artifactPath == "" {
		return fmt.Errorf("artifact path required for execution")
	}

	runErr := run(root, runtime, environment, "run", 4*time.Minute, "run", "research-delivery-probe", "--set", "registry.history_path="+filepath.Join(root, "registry.db"))
	if runErr != nil {
		return runErr
	}

	logBytes, readErr := os.ReadFile(filepath.Join(root, "run.log"))
	if readErr != nil {
		return readErr
	}
	var reportLine string
	for _, line := range strings.Split(string(logBytes), "\n") {
		if strings.HasPrefix(line, "RESEARCH_DELIVERY_PASS ") {
			reportLine = line
			break
		}
	}
	if reportLine == "" {
		return fmt.Errorf("missing RESEARCH_DELIVERY_PASS in run.log: %s", root)
	}
	fmt.Println(reportLine)
	return nil
}

func main() {
	if err := check(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
