// SPDX-License-Identifier: MIT
// Bounded Bee acceptance fixture for research delivery.
package main

import (
	"context"
	"crypto/sha256"
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
	if err := os.CopyFS(filepath.Join(review, "modules"), os.DirFS(filepath.Join(root, "modules"))); err != nil {
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
	measurement := flag.Bool("measurement", false, "prove HTTP measurements after governed activation")
	live := flag.Bool("live", false, "also require managed Gemini to request access and measure through MCP")
	flag.Parse()
	if *live && !*measurement {
		return fmt.Errorf("live requires measurement")
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
			if !ok || (kind != "process.lua" && kind != "library.lua" && kind != "function.lua") {
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
	if err = os.CopyFS(filepath.Join(root, "modules"), os.DirFS(filepath.Join(repo, "modules"))); err != nil {
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
	if *live {
		agy, locateErr := exec.LookPath("agy")
		if locateErr != nil {
			return locateErr
		}
		overrides["agy"], err = filepath.Abs(agy)
		if err != nil {
			return err
		}
		overrides["home"], err = os.UserHomeDir()
		if err != nil {
			return err
		}
	}
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
	if *measurement {
		if len(entries) == 0 {
			return fmt.Errorf("measurement requires reviewed artifact")
		}
		if err = stageMeasurement(repo, root, entries); err != nil {
			return err
		}
		if *live {
			if err = stageLiveMeasurement(root); err != nil {
				return err
			}
		}
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

	runDeadline := 4 * time.Minute
	if *live {
		runDeadline = 6 * time.Minute
	}
	runErr := run(root, runtime, environment, "run", runDeadline, "run", "research-delivery-probe", "--set", "registry.history_path="+filepath.Join(root, "registry.db"))
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
	if *measurement {
		found := false
		for _, line := range strings.Split(string(logBytes), "\n") {
			if strings.HasPrefix(line, "RESEARCH_MEASUREMENT_PASS ") {
				fmt.Println(line)
				found = true
			}
		}
		if !found {
			return fmt.Errorf("missing RESEARCH_MEASUREMENT_PASS in %s", root)
		}
	}
	fmt.Println(reportLine)
	if *measurement {
		if err = run(root, runtime, environment, "recovery", 60*time.Second, "run", "research-recovery-probe", "--set", "registry.history_path="+filepath.Join(root, "registry.db")); err != nil {
			return err
		}
		recovered, readErr := os.ReadFile(filepath.Join(root, "recovery.log"))
		if readErr != nil {
			return readErr
		}
		if !strings.Contains(string(recovered), "RESEARCH_RECOVERY_PASS "+artifactDigest) {
			return fmt.Errorf("missing exact recovery proof in %s", root)
		}
		fmt.Println("RESEARCH_RECOVERY_PASS", artifactDigest)
		if *live {
			if err = run(root, runtime, environment, "live", 4*time.Minute, "run", "research-live-measurement", "--set", "registry.history_path="+filepath.Join(root, "registry.db")); err != nil {
				return err
			}
			liveBytes, readErr := os.ReadFile(filepath.Join(root, "live.log"))
			if readErr != nil {
				return readErr
			}
			report := ""
			for _, line := range strings.Split(string(liveBytes), "\n") {
				if strings.HasPrefix(line, "RESEARCH_LIVE_MEASUREMENT_PASS ") {
					report = line
				}
			}
			if report == "" {
				return fmt.Errorf("live Gemini did not report verified measurements in %s", root)
			}
			fmt.Println(report)
			// The UI must show the newest real provider-driven observations.
			file, openErr := os.OpenFile(filepath.Join(root, "run.log"), os.O_APPEND|os.O_WRONLY, 0600)
			if openErr != nil {
				return openErr
			}
			_, writeErr := fmt.Fprintln(file, "RESEARCH_MEASUREMENT_PASS "+strings.TrimPrefix(report, "RESEARCH_LIVE_MEASUREMENT_PASS "))
			closeErr := file.Close()
			if writeErr != nil {
				return writeErr
			}
			if closeErr != nil {
				return closeErr
			}
		}
		if err = checkResearchDesktop(root, runtime, environment); err != nil {
			return err
		}
		fmt.Println("RESEARCH_DESKTOP_PASS", artifactDigest)
	}
	return nil
}

// The tool imports the approved candidate. Lint it together with the supplied
// artifact in the review tree; invoke it only after the real destination apply.
func stageMeasurement(repo, root string, entries []interface{}) error {
	// Admit the dashboard reader before measuring the activation base. Changing
	// host admission after approval correctly invalidates recovery of that base.
	admissionPath := filepath.Join(root, "src/security/_index.yaml")
	admissionBytes, err := os.ReadFile(admissionPath)
	if err != nil {
		return err
	}
	var admission map[string]interface{}
	if err = yaml.Unmarshal(admissionBytes, &admission); err != nil {
		return err
	}
	for _, raw := range admission["entries"].([]interface{}) {
		entry := raw.(map[string]interface{})
		if entry["name"] == "application_admission" {
			entry["bindings"] = append(entry["bindings"].([]interface{}), map[string]interface{}{
				"definition_id": "bee.research.demo:app", "policies": []string{"bee:ordinary_app_subsystem_boundary", "bee:gateway_tool_read_policy"},
			})
		}
	}
	admissionBytes, err = yaml.Marshal(admission)
	if err != nil {
		return err
	}
	if err = os.WriteFile(admissionPath, admissionBytes, 0600); err != nil {
		return err
	}
	gatewayPath := filepath.Join(root, "modules/gateway/src/api/_index.yaml")
	gatewayBytes, err := os.ReadFile(gatewayPath)
	if err != nil {
		return err
	}
	var gateway map[string]interface{}
	if err = yaml.Unmarshal(gatewayBytes, &gateway); err != nil {
		return err
	}
	for _, raw := range gateway["entries"].([]interface{}) {
		entry := raw.(map[string]interface{})
		if entry["name"] == "mcp_http" {
			security := entry["security"].(map[string]interface{})
			security["policies"] = append(security["policies"].([]interface{}), "bee.research_measurement:tool_policy")
		}
	}
	gatewayBytes, err = yaml.Marshal(gateway)
	if err != nil {
		return err
	}
	if err = os.WriteFile(gatewayPath, gatewayBytes, 0600); err != nil {
		return err
	}
	fixture := filepath.Join(root, "src/research_measurement")
	if err := os.CopyFS(fixture, os.DirFS(filepath.Join(repo, "tests/fixtures/research_measurement"))); err != nil {
		return err
	}
	baseline, err := os.ReadFile(filepath.Join(repo, "modules/threads/src/records/canonical.lua"))
	if err != nil {
		return err
	}
	var candidate string
	for _, raw := range entries {
		entry := raw.(map[string]interface{})
		if entry["id"] == "bee.research.demo:canonical" {
			candidate = entry["data"].(map[string]interface{})["source"].(string)
		}
	}
	if candidate == "" {
		return fmt.Errorf("missing candidate source")
	}
	indexPath := filepath.Join(fixture, "_index.yaml")
	indexBytes, err := os.ReadFile(indexPath)
	if err != nil {
		return err
	}
	var index map[string]interface{}
	if err = yaml.Unmarshal(indexBytes, &index); err != nil {
		return err
	}
	for _, raw := range index["entries"].([]interface{}) {
		entry := raw.(map[string]interface{})
		if entry["name"] == "inputs" {
			entry["data"] = map[string]interface{}{
				"baseline_sha256":  fmt.Sprintf("%x", sha256.Sum256(baseline)),
				"candidate_sha256": fmt.Sprintf("%x", sha256.Sum256([]byte(candidate))),
			}
		}
	}
	encoded, err := yaml.Marshal(index)
	if err != nil {
		return err
	}
	if err = os.WriteFile(indexPath, encoded, 0600); err != nil {
		return err
	}
	benchmarkDir := filepath.Join(root, "src/research_benchmark")
	if err = os.MkdirAll(benchmarkDir, 0700); err != nil {
		return err
	}
	for _, name := range []string{"corpus.lua", "measure.lua"} {
		if err = copyFile(filepath.Join(benchmarkDir, name), filepath.Join(repo, "tests/fixtures/performance_research", name)); err != nil {
			return err
		}
	}
	benchmark := map[string]interface{}{"version": "1.0", "namespace": "bee.research_benchmark_probe", "entries": []interface{}{
		map[string]interface{}{"name": "canonical", "kind": "library.lua", "source": string(baseline)},
		map[string]interface{}{"name": "corpus", "kind": "library.lua", "source": "file://corpus.lua"},
		map[string]interface{}{"name": "measure", "kind": "library.lua", "source": "file://measure.lua", "modules": []string{"time"}, "imports": map[string]string{"corpus": "bee.research_benchmark_probe:corpus"}},
	}}
	encoded, err = yaml.Marshal(benchmark)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(benchmarkDir, "_index.yaml"), encoded, 0600)
}

// Configure the fixture host before Governance measures its activation base.
// The managed Agent receives the same measurement surface as the HTTP probe.
func stageLiveMeasurement(root string) error {
	measurementPath := filepath.Join(root, "src/research_measurement/_index.yaml")
	data, err := os.ReadFile(measurementPath)
	if err != nil {
		return err
	}
	var measurement map[string]interface{}
	if err = yaml.Unmarshal(data, &measurement); err != nil {
		return err
	}
	var surface map[string]interface{}
	for _, raw := range measurement["entries"].([]interface{}) {
		entry := raw.(map[string]interface{})
		if entry["name"] == "surface" {
			surface = entry["data"].(map[string]interface{})
		}
	}
	if surface == nil {
		return fmt.Errorf("measurement surface missing")
	}
	surface["access"] = map[string]interface{}{"workspace_id": "research-workspace", "policy": "research-live-measurement", "traits": []string{"research:measure"}}
	for _, relative := range []string{"src/harness/host/_index.yaml", "src/approvals/host/_index.yaml"} {
		path := filepath.Join(root, relative)
		data, err = os.ReadFile(path)
		if err != nil {
			return err
		}
		var document map[string]interface{}
		if err = yaml.Unmarshal(data, &document); err != nil {
			return err
		}
		changed := false
		for _, raw := range document["entries"].([]interface{}) {
			entry := raw.(map[string]interface{})
			if entry["name"] == "launch_policy_agy_batch" {
				policy := entry["data"].(map[string]interface{})
				policy["gateway_tools"] = []string{"thread_read", "thread_message", "research_measure"}
				policy["gateway_surface"] = surface
				changed = true
			}
			if entry["name"] == "approver_policies" {
				policy := entry
				policy["policies"] = append(policy["policies"].([]interface{}), map[string]interface{}{
					"name": "research-live-measurement", "approvers": []string{"bee.research_delivery.operator"}, "max_ttl_ms": 180000})
				changed = true
			}
		}
		if !changed {
			return fmt.Errorf("live fixture host configuration missing in %s", relative)
		}
		data, err = yaml.Marshal(document)
		if err != nil {
			return err
		}
		if err = os.WriteFile(path, data, 0600); err != nil {
			return err
		}
	}
	return nil
}

func main() {
	if err := check(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
