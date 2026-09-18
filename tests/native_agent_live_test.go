// SPDX-License-Identifier: MIT
package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func treeFingerprint(root string) (string, error) {
	if _, err := os.Lstat(root); err != nil {
		if os.IsNotExist(err) {
			return "absent", nil
		}
		return "", err
	}
	entries := []string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		value := relative + "\x00" + info.Mode().String()
		if info.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			value += "\x00" + target
		} else if info.Mode().IsRegular() {
			content, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			value += fmt.Sprintf("\x00%x", sha256.Sum256(content))
		}
		entries = append(entries, value)
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Strings(entries)
	return fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(entries, "\n")))), nil
}

type grokInspectSource struct {
	Type string `json:"type"`
	Path string `json:"path"`
}

type grokInspectReport struct {
	Hooks []struct {
		Event  string            `json:"event"`
		Source grokInspectSource `json:"source"`
	} `json:"hooks"`
	MCPServers []struct {
		Name   string            `json:"name"`
		Target string            `json:"target"`
		Source grokInspectSource `json:"source"`
	} `json:"mcpServers"`
}

func inspectGrok(executable, project, retainedHome, grokHome string) (grokInspectReport, error) {
	command := exec.Command(executable, "inspect", "--json")
	command.Dir = project
	command.Env = append(os.Environ(), "HOME="+retainedHome, "GROK_HOME="+grokHome)
	output, err := command.Output()
	if err != nil {
		return grokInspectReport{}, err
	}
	var report grokInspectReport
	if err := json.Unmarshal(output, &report); err != nil {
		return grokInspectReport{}, err
	}
	return report, nil
}

func grokCompositionStatus(report grokInspectReport, finalConfigPath, hooksDirectory string) (bool, bool, bool, bool) {
	userHook, beeHook, userMCP, beeMCP := false, false, false, false
	for _, hook := range report.Hooks {
		event := strings.ReplaceAll(strings.ToLower(hook.Event), "_", "")
		userHook = userHook || (event == "stop" && hook.Source.Type == "configToml" && filepath.Clean(hook.Source.Path) == filepath.Clean(finalConfigPath))
		beeHook = beeHook || (event == "sessionstart" && hook.Source.Type == "user" && filepath.Clean(hook.Source.Path) == filepath.Clean(hooksDirectory))
	}
	for _, server := range report.MCPServers {
		fromComposedConfig := server.Source.Type == "configToml" && filepath.Clean(server.Source.Path) == filepath.Clean(finalConfigPath)
		userMCP = userMCP || (server.Name == "user_fixture" && server.Target == "http://127.0.0.1:9/mcp" && fromComposedConfig)
		beeMCP = beeMCP || (server.Name == "bee" && fromComposedConfig)
	}
	return userHook, beeHook, userMCP, beeMCP
}

// This opt-in acceptance starts the installed Agy binary through Bee without a
// model prompt. The wrapper only selects a disposable log path; Bee still owns
// every configuration argument and file delivered to the provider.
func TestActualAgyManagedStartup(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("AGY_BIN")
	if binary == "" || executable == "" {
		t.Fatal("BEE_BINARY and AGY_BIN are required")
	}
	var err error
	if binary, err = filepath.Abs(binary); err != nil {
		t.Fatal(err)
	}
	if executable, err = filepath.Abs(executable); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	logPath := filepath.Join(root, "agy.log")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	globalMarker := filepath.Join(home, ".gemini", "global-settings-marker")
	if err := os.MkdirAll(filepath.Dir(globalMarker), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(globalMarker, []byte("ordinary-global-settings"), 0600); err != nil {
		t.Fatal(err)
	}
	wrapper := "#!/bin/sh\nexec " + shellQuote(executable) + " --log-file " + shellQuote(logPath) + " \"$@\"\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "agy"), []byte(wrapper), 0700); err != nil {
		t.Fatal(err)
	}
	ui, err := newDesktopWithArguments(binary, project, state, home, []string{"agy"})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		ui.close()
		if err := stopFixtureOwners(binary, state); err != nil {
			t.Errorf("stop fixture owners: %v", err)
		}
	}()
	deadline := time.Now().Add(30 * time.Second)
	loadedHooks := false
	for time.Now().Before(deadline) {
		data, readErr := os.ReadFile(logPath)
		if readErr == nil && strings.Contains(string(data), "loaded 1 named hooks") {
			loadedHooks = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !loadedHooks {
		data, _ := os.ReadFile(logPath)
		t.Fatalf("actual Agy did not load Bee's added customization root: %s", string(data))
	}
	for _, path := range []string{
		filepath.Join(home, ".gemini", "config", "mcp_config.json"),
		filepath.Join(home, ".gemini", "config", "hooks.json"),
		filepath.Join(home, ".gemini", "GEMINI.md"),
	} {
		data, err := os.ReadFile(path)
		if err == nil && (strings.Contains(string(data), "/mcp/") || strings.Contains(string(data), "hook-post") || strings.Contains(string(data), "generated by bee")) {
			t.Fatalf("Bee configuration appeared in Agy's global tree: %s", path)
		}
		if err != nil && !os.IsNotExist(err) {
			t.Fatalf("inspect Agy global path %s: %v", path, err)
		}
	}
	if _, err := os.Stat(filepath.Join(project, ".agents")); !os.IsNotExist(err) {
		t.Fatal("Bee wrote Agy customization into the project")
	}
	marker, err := os.ReadFile(globalMarker)
	if err != nil || string(marker) != "ordinary-global-settings" {
		t.Fatalf("global settings marker changed: %q, %v", string(marker), err)
	}
	found := map[string]bool{}
	err = filepath.Walk(state, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if info.Mode().IsRegular() {
			relative := filepath.ToSlash(path)
			for _, name := range []string{".agents/mcp_config.json", ".agents/hooks.json"} {
				if strings.HasSuffix(relative, name) {
					found[name] = true
				}
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{".agents/mcp_config.json", ".agents/hooks.json"} {
		if !found[name] {
			t.Fatal(fmt.Sprintf("Bee did not materialize %s in retained state", name))
		}
	}
	if err := ui.quit(); err != nil {
		t.Fatal(err)
	}
	t.Log("Actual Agy loaded Bee's additional customization root, left global/project configuration untouched, and detached promptly")
}

// This opt-in acceptance uses a real CLI without submitting a model prompt. It
// proves Grok's native managed/user configuration layers compose Bee's private
// MCP with a selective snapshot of ordinary global configuration.
func TestActualGrokManagedStartup(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("GROK_BIN")
	loginSource := os.Getenv("GROK_LOGIN_FILE")
	if binary == "" || executable == "" {
		t.Fatal("BEE_BINARY and GROK_BIN are required")
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	executable, err = filepath.Abs(executable)
	if err != nil {
		t.Fatal(err)
	}
	root := os.Getenv("BEE_GROK_LIVE_ROOT")
	if root == "" {
		root = t.TempDir()
	} else {
		if err := os.MkdirAll(root, 0700); err != nil {
			t.Fatal(err)
		}
		t.Logf("retaining failed Grok acceptance state in %s", root)
	}
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(executable, filepath.Join(project, "bin", "grok")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, ".grok"), 0700); err != nil {
		t.Fatal(err)
	}
	globalConfig := "[ui]\nscreen_mode = \"minimal\"\n[permission]\nallow = [\"Read(*)\"]\n[mcp_servers.user_fixture]\nurl = \"http://127.0.0.1:9/mcp\"\n[[hooks.Stop]]\nmatcher = \"\"\n[[hooks.Stop.hooks]]\ntype = \"command\"\ncommand = \"true\"\n"
	globalConfigPath := filepath.Join(home, ".grok", "config.toml")
	if err := os.WriteFile(globalConfigPath, []byte(globalConfig), 0600); err != nil {
		t.Fatal(err)
	}
	if loginSource != "" {
		login, err := os.ReadFile(loginSource)
		if err != nil {
			t.Fatal("machine login unavailable")
		}
		if err := os.WriteFile(filepath.Join(home, ".grok", "auth.json"), login, 0600); err != nil {
			t.Fatal(err)
		}
	}
	globalBefore, err := treeFingerprint(filepath.Join(home, ".grok"))
	if err != nil {
		t.Fatal(err)
	}
	projectBefore, err := treeFingerprint(filepath.Join(project, ".grok"))
	if err != nil {
		t.Fatal(err)
	}
	ui, err := newDesktop(binary, project, state, home)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		ui.close()
		if err := stopFixtureOwners(binary, state); err != nil {
			t.Errorf("stop fixture owners: %v", err)
		}
	}()
	if err := ui.waitFor("Choose a profile", 25*time.Second); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		_, before, _ := ui.snapshot()
		if err := ui.send("\x1b[B"); err != nil {
			t.Fatal(err)
		}
		if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
			t.Fatal(err)
		}
	}
	if err := ui.send("\r"); err != nil {
		t.Fatal(err)
	}
	if loginSource == "" {
		if err := ui.waitFor("Sign in to Grok", 25*time.Second); err != nil {
			t.Fatal(err)
		}
		var basePath string
		if err := filepath.Walk(state, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.Mode().IsRegular() && strings.HasSuffix(filepath.ToSlash(path), "/.grok/.bee-global-config.toml") {
				basePath = path
			}
			return nil
		}); err != nil || basePath == "" {
			t.Fatalf("find clean-start Grok private base: %q, %v", basePath, err)
		}
		base, err := os.ReadFile(basePath)
		if err != nil || string(base) != globalConfig {
			t.Fatalf("clean-start Grok private base differs: %v", err)
		}
		grokHome := filepath.Dir(basePath)
		final, err := os.ReadFile(filepath.Join(grokHome, "config.toml"))
		if err != nil || !strings.Contains(string(final), "[mcp_servers.bee]") || !strings.Contains(string(final), "Read(*)") {
			t.Fatalf("clean-start Grok private configuration is incomplete: %v", err)
		}
		hooksDirectory := filepath.Join(grokHome, "hooks")
		if _, err := os.Stat(filepath.Join(hooksDirectory, "bee.json")); err != nil {
			t.Fatalf("clean-start Grok Bee hooks are missing: %v", err)
		}
		report, err := inspectGrok(executable, project, filepath.Dir(grokHome), grokHome)
		if err != nil {
			t.Fatalf("inspect clean-start Grok composition: %v", err)
		}
		userHook, beeHook, userMCP, beeMCP := grokCompositionStatus(report, filepath.Join(grokHome, "config.toml"), hooksDirectory)
		if !userHook || !beeHook || !userMCP || !beeMCP {
			t.Fatalf("clean-start Grok composition is incomplete: user_hook=%v bee_hook=%v user_mcp=%v bee_mcp=%v", userHook, beeHook, userMCP, beeMCP)
		}
		if err := ui.quit(); err != nil {
			t.Fatal(err)
		}
		ui, err = newDesktop(binary, project, state, home)
		if err != nil {
			t.Fatal(err)
		}
		if err := ui.waitFor("Sign in to Grok", 25*time.Second); err != nil {
			t.Fatal(fmt.Errorf("restart did not restore the unauthenticated Grok window: %w", err))
		}
		if err := ui.quit(); err != nil {
			t.Fatal(err)
		}
		globalAfter, globalErr := treeFingerprint(filepath.Join(home, ".grok"))
		projectAfter, projectErr := treeFingerprint(filepath.Join(project, ".grok"))
		if globalErr != nil || projectErr != nil || globalAfter != globalBefore || projectAfter != projectBefore {
			t.Fatalf("clean start changed global/project Grok trees: global=%v project=%v errors=%v/%v", globalAfter == globalBefore, projectAfter == projectBefore, globalErr, projectErr)
		}
		t.Log("Actual Grok clean start presented login, retained private Bee configuration, canceled and restored after restart")
		return
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
		if err != nil {
			t.Fatal(err)
		}
		rows, err := db.Query("SELECT record_json FROM bee_thread_records WHERE kind='observation' AND source='bee'")
		found := false
		if err == nil {
			for rows.Next() {
				var raw string
				if err := rows.Scan(&raw); err != nil {
					rows.Close()
					db.Close()
					t.Fatal(err)
				}
				var rec struct {
					Body struct {
						Data struct {
							Name    string `json:"event_name"`
							Payload string `json:"payload_json"`
						} `json:"data"`
					} `json:"body"`
				}
				if json.Unmarshal([]byte(raw), &rec) != nil || rec.Body.Data.Name != "bee.harness.hook" {
					continue
				}
				var payload struct {
					Event  string         `json:"event"`
					Fields map[string]any `json:"fields"`
				}
				if json.Unmarshal([]byte(rec.Body.Data.Payload), &payload) == nil && payload.Event == "SessionStart" {
					session, ok := payload.Fields["session_id"].(string)
					found = found || (ok && session != "")
				}
			}
			readErr := rows.Err()
			rows.Close()
			if readErr != nil {
				db.Close()
				t.Fatal(readErr)
			}
		}
		db.Close()
		if found {
			var basePath string
			var retainedFiles []string
			walkErr := filepath.Walk(state, func(path string, info os.FileInfo, err error) error {
				if err != nil {
					return err
				}
				if info.Mode().IsRegular() && filepath.ToSlash(path) != "" && strings.HasSuffix(filepath.ToSlash(path), "/.grok/.bee-global-config.toml") {
					basePath = path
				}
				if info.Mode().IsRegular() && (strings.Contains(filepath.ToSlash(path), "/sessions/") || strings.Contains(filepath.ToSlash(path), "/placement")) {
					retainedFiles = append(retainedFiles, filepath.ToSlash(path))
				}
				return nil
			})
			if walkErr != nil || basePath == "" {
				t.Fatalf("find retained Grok private composition base: %q, %v; retained files: %v", basePath, walkErr, retainedFiles)
			}
			base, err := os.ReadFile(basePath)
			if err != nil || string(base) != globalConfig {
				t.Fatalf("retained Grok global configuration differs: %v", err)
			}
			grokHome := filepath.Dir(basePath)
			retainedHome := filepath.Dir(grokHome)
			finalConfigPath := filepath.Join(grokHome, "config.toml")
			beeHooksPath := filepath.Join(grokHome, "hooks", "bee.json")
			finalConfig, err := os.ReadFile(finalConfigPath)
			if err != nil || !strings.Contains(string(finalConfig), "[mcp_servers.bee]") ||
				!strings.Contains(string(finalConfig), "screen_mode") || !strings.Contains(string(finalConfig), "Read(*)") {
				t.Fatalf("private Grok configuration did not preserve global settings and add Bee MCP: %v", err)
			}
			if _, err := os.Stat(beeHooksPath); err != nil {
				t.Fatalf("private Grok Bee hook file is missing: %v", err)
			}
			report, err := inspectGrok(executable, project, retainedHome, grokHome)
			if err != nil {
				t.Fatalf("actual Grok inspect: %v", err)
			}
			userHook, beeHook, userMCP, beeMCP := grokCompositionStatus(report, finalConfigPath, filepath.Dir(beeHooksPath))
			if !userHook || !beeHook || !userMCP || !beeMCP {
				t.Fatalf("actual Grok did not preserve user hooks/MCP and add Bee hooks/MCP: user_hook=%v bee_hook=%v user_mcp=%v bee_mcp=%v", userHook, beeHook, userMCP, beeMCP)
			}
			unchanged, err := os.ReadFile(globalConfigPath)
			if err != nil || string(unchanged) != globalConfig {
				t.Fatal("Bee changed the global Grok configuration")
			}
			t.Log("Actual Grok composed the private global snapshot and Bee MCP, emitted SessionStart, and received no prompt")
			if err := ui.quit(); err != nil {
				t.Fatal(err)
			}
			globalAfter, globalErr := treeFingerprint(filepath.Join(home, ".grok"))
			projectAfter, projectErr := treeFingerprint(filepath.Join(project, ".grok"))
			if globalErr != nil || projectErr != nil || globalAfter != globalBefore || projectAfter != projectBefore {
				t.Fatalf("authenticated start changed global/project Grok trees: global=%v project=%v errors=%v/%v", globalAfter == globalBefore, projectAfter == projectBefore, globalErr, projectErr)
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	screen, _, _ := ui.snapshot()
	t.Fatalf("actual Grok startup hook did not commit within 30 seconds:\n%s", screen)
}
