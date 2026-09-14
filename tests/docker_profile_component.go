// SPDX-License-Identifier: MIT
// Composes the optional Codex Docker declaration with production Bee and proves
// requirement linking plus ordinary Agent command discovery. It does not start
// a container or claim that the fixture image contains Codex.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

const dockerProfileImage = "sha256:d529dd0c6e5597ac7e4a3e2dea65c3fcc6173f4cae713c409265c1dd9914a11b"
const dockerProfileUser = "1001:1002"

type dockerProfileIndex struct {
	Version   string                   `yaml:"version"`
	Namespace string                   `yaml:"namespace"`
	Entries   []map[string]interface{} `yaml:"entries"`
}

func dockerProfileCopy(destination, source string) error {
	if err := os.MkdirAll(destination, 0700); err != nil {
		return err
	}
	return os.CopyFS(destination, os.DirFS(source))
}

func dockerProfileRun(ctx context.Context, directory, runtime string, environment []string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, runtime, args...)
	command.Dir = directory
	command.Env = append(os.Environ(), environment...)
	return command.CombinedOutput()
}

func dockerProfileConfigure(indexPath string) error {
	raw, err := os.ReadFile(indexPath)
	if err != nil {
		return err
	}
	var index dockerProfileIndex
	if err := yaml.Unmarshal(raw, &index); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, entry := range index.Entries {
		name, _ := entry["name"].(string)
		switch name {
		case "image":
			entry["default"] = dockerProfileImage
			seen[name] = true
		case "user":
			entry["default"] = dockerProfileUser
			seen[name] = true
		}
	}
	if !seen["image"] || !seen["user"] {
		return fmt.Errorf("optional component omitted image or user requirement")
	}
	configured, err := yaml.Marshal(index)
	if err != nil {
		return err
	}
	return os.WriteFile(indexPath, configured, 0600)
}

func dockerProfileEnvironment(root string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	environment := []string{
		"HOME=" + filepath.Join(root, "home"),
		"XDG_CONFIG_HOME=" + filepath.Join(root, "config"),
		"XDG_DATA_HOME=" + filepath.Join(root, "data"),
		"XDG_STATE_HOME=" + filepath.Join(root, "state"),
	}
	for _, name := range names {
		environment = append(environment, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(root, name+".db"))
	}
	return environment
}

func dockerProfileMain() error {
	runtimeFlag := flag.String("runtime", "", "Wippy runtime")
	rootFlag := flag.String("root", ".", "Bee repository root")
	flag.Parse()
	if *runtimeFlag == "" {
		return fmt.Errorf("runtime is required")
	}
	repository, err := filepath.Abs(*rootFlag)
	if err != nil {
		return err
	}
	runtime, err := filepath.Abs(*runtimeFlag)
	if err != nil {
		return err
	}
	root, err := os.MkdirTemp("", "bee-codex-docker-component-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	for _, directory := range []string{"home", "config", "data", "state"} {
		if err := os.MkdirAll(filepath.Join(root, directory), 0700); err != nil {
			return err
		}
	}
	if err := dockerProfileCopy(filepath.Join(root, "src"), filepath.Join(repository, "src")); err != nil {
		return err
	}
	component := filepath.Join(root, "src", "optional", "codex_docker")
	if err := dockerProfileCopy(component, filepath.Join(repository, "modules", "bee-driver-codex-docker", "src")); err != nil {
		return err
	}
	if err := dockerProfileConfigure(filepath.Join(component, "_index.yaml")); err != nil {
		return err
	}
	if err := dockerProfileCopy(filepath.Join(root, "src", "tests", "codex_docker_component"), filepath.Join(repository, "tests", "fixtures", "codex_docker_component")); err != nil {
		return err
	}
	rootIndex := filepath.Join(root, "src", "_index.yaml")
	rawRoot, err := os.ReadFile(rootIndex)
	if err != nil {
		return err
	}
	rawRoot = append(rawRoot, []byte("\n- name: codex_docker_test_dependency\n  kind: ns.dependency\n  component: wippy/test\n  version: 0.4.17\n")...)
	if err := os.WriteFile(rootIndex, rawRoot, 0600); err != nil {
		return err
	}
	lock, err := os.ReadFile(filepath.Join(repository, "wippy.lock"))
	if err != nil {
		return err
	}
	dependencies, err := os.ReadFile(filepath.Join(repository, "tests", "dependencies.yaml"))
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "wippy.lock"), append(append(lock, '\n'), dependencies...), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, ".wippy.yaml"), []byte("version: '1.0'\nshutdown:\n  timeout: 2s\n"), 0600); err != nil {
		return err
	}
	environment := dockerProfileEnvironment(root)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if output, err := dockerProfileRun(ctx, root, runtime, environment, "install"); err != nil {
		return fmt.Errorf("fixture install: %w\n%s", err, output)
	}
	if output, err := dockerProfileRun(ctx, root, runtime, environment, "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"); err != nil {
		return fmt.Errorf("fixture lint: %w\n%s", err, output)
	}
	output, err := dockerProfileRun(ctx, root, runtime, environment, "test", "--host", "bee:terminal")
	if err != nil {
		return fmt.Errorf("component acceptance: %w\n%s", err, output)
	}
	if !strings.Contains(string(output), "1 tests") || !strings.Contains(string(output), "PASSED") {
		return fmt.Errorf("component acceptance omitted exact test result\n%s", output)
	}
	fmt.Println("PASS: optional Codex Docker component linked host image/user requirements and contributed one ordinary Agent command while preserving native Codex")
	return nil
}

func main() {
	if err := dockerProfileMain(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
