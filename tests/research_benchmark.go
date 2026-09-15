// SPDX-License-Identifier: MIT
// Offline prerequisite for the live research workflow. Candidate publication,
// provider execution and dashboard acceptance are separate gates.
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
)

func check() error {
	repoFlag := flag.String("root", "..", "Bee source root")
	runtimeFlag := flag.String("runtime", "", "native runtime executable")
	flag.Parse()
	repo, err := filepath.Abs(*repoFlag)
	if err != nil {
		return err
	}
	runtime := *runtimeFlag
	if runtime == "" {
		runtime = filepath.Join(repo, ".wippy/bin/bee-wippy")
	}
	runtime, err = filepath.Abs(runtime)
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "bee-research-benchmark-")
	if err != nil {
		return err
	}
	fmt.Println("Private evidence:", root)
	lock, err := os.ReadFile(filepath.Join(repo, "wippy.lock"))
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(root, "wippy.lock"), lock, 0600); err != nil {
		return err
	}
	if err = os.CopyFS(filepath.Join(root, "src"), os.DirFS(filepath.Join(repo, "tests/fixtures/performance_research"))); err != nil {
		return err
	}
	source, err := os.ReadFile(filepath.Join(repo, "src/threads/records/canonical.lua"))
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(root, "src/canonical.lua"), source, 0600); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nregistry:\n  enable_history: false\nshutdown:\n  timeout: 1s\n"), 0600); err != nil {
		return err
	}
	for _, step := range []struct {
		name     string
		args     []string
		deadline time.Duration
	}{
		{"lint", []string{"lint"}, time.Minute},
		{"run", []string{"run", "research-benchmark-probe"}, 15 * time.Second},
	} {
		ctx, cancel := context.WithTimeout(context.Background(), step.deadline)
		cmd := exec.CommandContext(ctx, runtime, step.args...)
		cmd.Dir = root
		cmd.WaitDelay = time.Second
		output, runErr := cmd.CombinedOutput()
		cancel()
		if err = os.WriteFile(filepath.Join(root, step.name+".log"), output, 0600); err != nil {
			return err
		}
		if runErr != nil {
			return fmt.Errorf("%s: %w; evidence %s", step.name, runErr, root)
		}
		if step.name == "run" {
			if strings.Count(string(output), "RESEARCH_SPIN_STARTED") != 3 {
				return fmt.Errorf("CPU cancellation probe did not start three functions")
			}
			var measurement map[string]interface{}
			for _, line := range strings.Split(string(output), "\n") {
				if strings.HasPrefix(line, "RESEARCH_BASELINE ") {
					if measurement != nil {
						return fmt.Errorf("duplicate baseline")
					}
					if err = json.Unmarshal([]byte(strings.TrimPrefix(line, "RESEARCH_BASELINE ")), &measurement); err != nil {
						return err
					}
				}
			}
			if measurement == nil || (measurement["outcome"] != "passed" && measurement["outcome"] != "invalid") {
				return fmt.Errorf("missing baseline verdict: %s", root)
			}
			fmt.Println("Baseline correctness:", measurement["outcome"], measurement["correctness_error"])
			samples, ok := measurement["samples"].([]interface{})
			if !ok || len(samples) != 7 {
				return fmt.Errorf("expected seven baseline samples")
			}
			for _, sample := range samples {
				if value, ok := sample.(float64); !ok || value <= 0 {
					return fmt.Errorf("invalid sample")
				}
			}
			measurement["source_sha256"] = fmt.Sprintf("%x", sha256.Sum256(source))
			measurement["runtime"] = runtime
			data, marshalErr := json.MarshalIndent(measurement, "", "  ")
			if marshalErr != nil {
				return marshalErr
			}
			if err = os.WriteFile(filepath.Join(root, "baseline.json"), data, 0600); err != nil {
				return err
			}
		}
	}
	fmt.Println("RESEARCH_BENCHMARK_PASS: correctness verdict, seven baseline samples, cancellation smoke and bounded runtime exit")
	return nil
}

func main() {
	if err := check(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
