// SPDX-License-Identifier: MIT
// Disposable source/pack acceptance for the Hive Manager app boundary.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func copyTree(dst, src string) error { return os.CopyFS(dst, os.DirFS(src)) }

func run(runtime, dir, marker string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), isolatedEnvironment(dir)...)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return fmt.Errorf("%s: %w\n%s", strings.Join(args, " "), ctx.Err(), out)
	}
	if err != nil {
		return fmt.Errorf("%s: %w\n%s", strings.Join(args, " "), err, out)
	}
	if marker != "" && !strings.Contains(string(out), marker) {
		return fmt.Errorf("missing %q:\n%s", marker, out)
	}
	return nil
}

func isolatedEnvironment(dir string) []string {
	names := []string{"workspace", "threads", "client", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance"}
	env := []string{"HOME=" + filepath.Join(dir, "home"), "XDG_CONFIG_HOME=" + filepath.Join(dir, "config"), "XDG_DATA_HOME=" + filepath.Join(dir, "data"), "XDG_STATE_HOME=" + filepath.Join(dir, "state"), "BEE_PLACEMENT_ROOT=" + filepath.Join(dir, "placement")}
	for _, name := range names {
		env = append(env, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(dir, name+".db"))
	}
	return env
}

func exercise(runtime, root, mode string, packed bool) error {
	dir, err := os.MkdirTemp("", "bee-hive-manager-app-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	if err := copyTree(filepath.Join(dir, "src"), filepath.Join(root, "src")); err != nil {
		return err
	}
	if err := copyTree(filepath.Join(dir, "modules"), filepath.Join(root, "modules")); err != nil {
		return err
	}
	if err := copyTree(filepath.Join(dir, "src", "tests", "hive_manager_probe"), filepath.Join(root, "tests", "fixtures", "hive_manager_app")); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock", "wippy.yaml"} {
		data, readErr := os.ReadFile(filepath.Join(root, name))
		if readErr != nil {
			return readErr
		}
		if writeErr := os.WriteFile(filepath.Join(dir, name), data, 0600); writeErr != nil {
			return writeErr
		}
	}
	fake := filepath.Join(dir, "src", "tests", "hive_manager_probe", "directory.lua")
	data, err := os.ReadFile(fake)
	if err != nil {
		return err
	}
	updated := strings.Replace(string(data), `local MODE = "slow"`, `local MODE = "`+mode+`"`, 1)
	if mode != "slow" && updated == string(data) {
		return fmt.Errorf("missing fake-directory mode for %s", mode)
	}
	if err := os.WriteFile(filepath.Join(dir, "src", "apps", "hive", "directory.lua"), []byte(updated), 0600); err != nil {
		return err
	}
	manifest := filepath.Join(dir, "src", "apps", "hive", "_index.yaml")
	data, err = os.ReadFile(manifest)
	if err != nil {
		return err
	}
	updated = strings.Replace(string(data), "source: file://directory.lua\n  imports:", "source: file://directory.lua\n  modules: [time, process, ctx]\n  imports:", 1)
	if updated == string(data) {
		return fmt.Errorf("missing staged directory declaration")
	}
	updated = strings.Replace(updated, "actions: [registry.get, system.read]", "actions: [registry.get, system.read, process.send, process.context]", 1)
	if !strings.Contains(updated, "process.context") {
		return fmt.Errorf("missing staged manager policy")
	}
	if err := os.WriteFile(manifest, []byte(updated), 0600); err != nil {
		return err
	}
	if mode == "stale" {
		app := filepath.Join(dir, "src", "apps", "hive", "app.lua")
		data, err := os.ReadFile(app)
		if err != nil {
			return err
		}
		// Reproduce a catalog/selection update while the owner response is in
		// flight. Inject only into this disposable copy, at the response boundary.
		boundary := "                local asked = dialog\n                dialog = nil"
		if strings.Count(string(data), boundary) != 1 {
			return fmt.Errorf("missing manager confirmation response boundary")
		}
		updated := strings.Replace(string(data), boundary, boundary+"\n                model.move(state, 1)", 1)
		if err := os.WriteFile(app, []byte(updated), 0600); err != nil {
			return err
		}
	}
	for _, name := range []string{"home", "config", "data", "state"} {
		if err := os.MkdirAll(filepath.Join(dir, name), 0700); err != nil {
			return err
		}
	}
	rootManifest := filepath.Join(dir, "src", "_index.yaml")
	data, err = os.ReadFile(rootManifest)
	if err != nil {
		return err
	}
	if err := os.WriteFile(rootManifest, []byte(strings.Replace(string(data), "hide_logs: true", "hide_logs: false", 1)), 0600); err != nil {
		return err
	}
	if err := run(runtime, dir, "", "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"); err != nil {
		return err
	}
	marker := "BEE_HIVE_MANAGER_APP_PROBE: OK " + mode
	if !packed {
		return run(runtime, dir, marker, "run", "hive-manager-app-probe", mode, "--host", "bee:terminal")
	}
	// A packed Bee is a source-free deployment pinning one pack per module.
	deployment := filepath.Join(dir, "packed")
	build := exec.Command("python3", filepath.Join(root, "tests", "pack_deployment.py"), dir, deployment)
	build.Env = append(os.Environ(), "BEE_RUNTIME="+runtime)
	if out, err := build.CombinedOutput(); err != nil {
		return fmt.Errorf("deployment build: %w\n%s", err, out)
	}
	return run(runtime, deployment, marker, "run", "hive-manager-app-probe", mode, "--host", "bee:terminal")
}

func main() {
	runtime := os.Getenv("BEE_RUNTIME")
	if runtime == "" {
		runtime = ".wippy/bin/bee-wippy"
	}
	runtime, _ = filepath.Abs(runtime)
	root, _ := os.Getwd()
	for _, packed := range []bool{false, true} {
		for _, mode := range []string{"unavailable", "slow", "stale"} {
			if err := exercise(runtime, root, mode, packed); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			fmt.Printf("Hive Manager %s packed=%t: passed\n", mode, packed)
		}
	}
	// A process exit alone is not acceptance: prove an explicit fixture-entry
	// failure is observed as such by the bounded runner.
	if err := counterfactual(runtime, root); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Hive Manager app: source/pack unavailable, slow-query close, and stale confirmation passed")
}

func counterfactual(runtime, root string) error {
	dir, err := os.MkdirTemp("", "bee-hive-manager-counterfactual-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	for _, name := range []string{"home", "config", "data", "state"} {
		if err := os.MkdirAll(filepath.Join(dir, name), 0700); err != nil {
			return err
		}
	}
	if err := copyTree(filepath.Join(dir, "src"), filepath.Join(root, "src")); err != nil {
		return err
	}
	if err := copyTree(filepath.Join(dir, "modules"), filepath.Join(root, "modules")); err != nil {
		return err
	}
	if err := copyTree(filepath.Join(dir, "src", "tests", "hive_manager_probe"), filepath.Join(root, "tests", "fixtures", "hive_manager_app")); err != nil {
		return err
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock", "wippy.yaml"} {
		data, readErr := os.ReadFile(filepath.Join(root, name))
		if readErr != nil {
			return readErr
		}
		if writeErr := os.WriteFile(filepath.Join(dir, name), data, 0600); writeErr != nil {
			return writeErr
		}
	}
	mainFile := filepath.Join(dir, "src", "tests", "hive_manager_probe", "main.lua")
	data, err := os.ReadFile(mainFile)
	if err != nil {
		return err
	}
	data = []byte(strings.Replace(string(data), "local function main(mode: string?)", "local function main(mode: string?)\n    io.print(\"BEE_HIVE_MANAGER_APP_PROBE: COUNTERFACTUAL\")\n    error(\"counterfactual probe failure\")", 1))
	if err := os.WriteFile(mainFile, data, 0600); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, runtime, "run", "hive-manager-app-probe", "unavailable", "--host", "bee:terminal")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), isolatedEnvironment(dir)...)
	out, runErr := cmd.CombinedOutput()
	if ctx.Err() != nil || runErr == nil || !strings.Contains(string(out), "BEE_HIVE_MANAGER_APP_PROBE: COUNTERFACTUAL") {
		return fmt.Errorf("counterfactual was not explicitly rejected: context=%v error=%v output=%s", ctx.Err(), runErr, out)
	}
	return nil
}
