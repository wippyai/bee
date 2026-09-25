// SPDX-License-Identifier: MIT
// Durable opt-in acceptance for real Codex CLI conversation recovery.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const actualCodexWrapper = "__bee_codex_recovery_wrapper"

type actualCodexOutcome struct {
	ThreadID        string
	ThreadStarts    int
	Answer          string
	TurnCompleted   int
	TurnFailed      bool
	CommandComplete bool
	ToolUsed        bool
}

type actualCodexLaunch struct {
	Directory string
	Home      string
	CodexHome string
	Arguments []string
}

func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == actualCodexWrapper {
		os.Exit(runActualCodexWrapper(os.Args[2:]))
	}
	os.Exit(m.Run())
}

func actualCodexExecArguments(beeArgs []string) ([]string, string, error) {
	base := make([]string, 0, len(beeArgs)+8)
	resumeRef := ""
	for index := 0; index < len(beeArgs); index++ {
		if beeArgs[index] == "resume" {
			if resumeRef != "" || index+1 >= len(beeArgs) {
				return nil, "", errors.New("malformed Codex resume arguments")
			}
			resumeRef = beeArgs[index+1]
			index++
			continue
		}
		if beeArgs[index] == "--" {
			return nil, "", errors.New("Bee replayed a prompt to the Codex wrapper")
		}
		base = append(base, beeArgs[index])
	}
	base = append(base, "exec")
	if resumeRef != "" {
		base = append(base, "resume", resumeRef)
	}
	base = append(base, "--json", "--skip-git-repo-check", "-")
	return base, resumeRef, nil
}

func runActualCodexWrapper(arguments []string) int {
	if len(arguments) < 2 {
		return 2
	}
	executable, root, beeArgs := arguments[0], arguments[1], arguments[2:]
	phase := "first"
	if _, err := os.Stat(filepath.Join(os.Getenv("HOME"), "bee-session-proof")); err == nil {
		phase = "second"
	}
	report := filepath.Join(root, phase+"-launch")
	result := filepath.Join(root, phase+"-result.jsonl")
	task, err := os.ReadFile(filepath.Join(root, phase+"-task"))
	if err != nil {
		return 2
	}
	lines := []string{mustWorkingDirectory(), os.Getenv("HOME"), os.Getenv("CODEX_HOME")}
	lines = append(lines, beeArgs...)
	if err := os.WriteFile(report, []byte(strings.Join(lines, "\n")+"\n"), 0600); err != nil {
		return 2
	}
	actualArgs, _, argumentErr := actualCodexExecArguments(beeArgs)
	status := -1
	if argumentErr == nil {
		stdout, createErr := os.OpenFile(result, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
		if createErr == nil {
			stderr, stderrErr := os.OpenFile(result+".stderr", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
			if stderrErr == nil {
				command := exec.Command(executable, actualArgs...)
				command.Dir = lines[0]
				command.Env = os.Environ()
				command.Stdin = strings.NewReader(string(task))
				command.Stdout = stdout
				command.Stderr = stderr
				runErr := command.Run()
				status = 0
				if runErr != nil {
					status = 1
					var exitErr *exec.ExitError
					if errors.As(runErr, &exitErr) {
						status = exitErr.ExitCode()
					}
				}
				_ = stderr.Close()
			}
			_ = stdout.Close()
		}
	}
	_ = os.WriteFile(result+".status", []byte(fmt.Sprintf("%d\n", status)), 0600)
	_ = os.WriteFile(filepath.Join(os.Getenv("HOME"), "bee-session-proof"), []byte("retained\n"), 0600)
	fmt.Printf("BEE_RECOVERY_AGENT_READY_%s\n", phase)
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	return 0
}

func mustWorkingDirectory() string {
	value, err := os.Getwd()
	if err != nil {
		return ""
	}
	return value
}

func readActualCodexResult(path, expected string, requireCommand, forbidTools bool) (actualCodexOutcome, error) {
	file, err := os.Open(path)
	if err != nil {
		return actualCodexOutcome{}, errors.New("real Codex result missing")
	}
	defer file.Close()
	var outcome actualCodexOutcome
	lines := 0
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		lines++
		var envelope map[string]any
		if json.Unmarshal(scanner.Bytes(), &envelope) != nil {
			return actualCodexOutcome{}, errors.New("real Codex emitted malformed JSONL")
		}
		switch envelope["type"] {
		case "thread.started":
			outcome.ThreadStarts++
			threadID, _ := envelope["thread_id"].(string)
			if outcome.ThreadID != "" && outcome.ThreadID != threadID {
				return actualCodexOutcome{}, errors.New("real Codex changed thread identity within one turn")
			}
			outcome.ThreadID = threadID
		case "item.started", "item.updated", "item.completed":
			item, _ := envelope["item"].(map[string]any)
			kind, _ := item["type"].(string)
			if kind == "command_execution" || kind == "mcp_tool_call" || kind == "file_change" || kind == "web_search" {
				outcome.ToolUsed = true
			}
			if envelope["type"] == "item.completed" && kind == "agent_message" {
				outcome.Answer, _ = item["text"].(string)
			}
			if envelope["type"] == "item.completed" && kind == "command_execution" && item["status"] == "completed" {
				command, _ := item["command"].(string)
				output, _ := item["aggregated_output"].(string)
				if strings.Contains(command, "fixture.txt") && strings.Contains(output, expected) {
					outcome.CommandComplete = true
				}
			}
		case "turn.completed":
			outcome.TurnCompleted++
		case "turn.failed":
			outcome.TurnFailed = true
		}
	}
	if err := scanner.Err(); err != nil {
		return actualCodexOutcome{}, err
	}
	if outcome.TurnFailed || outcome.TurnCompleted != 1 || outcome.ThreadStarts != 1 || outcome.ThreadID == "" || strings.TrimSpace(outcome.Answer) != expected {
		return actualCodexOutcome{}, fmt.Errorf("real Codex result rejected (lines=%d, thread starts=%d, completed=%d, failed=%t, answer bytes=%d); content withheld", lines, outcome.ThreadStarts, outcome.TurnCompleted, outcome.TurnFailed, len(outcome.Answer))
	}
	if requireCommand && !outcome.CommandComplete {
		return actualCodexOutcome{}, errors.New("real Codex did not complete the source-file read command")
	}
	if forbidTools && outcome.ToolUsed {
		return actualCodexOutcome{}, errors.New("real Codex recovery used a tool")
	}
	return outcome, nil
}

func waitActualCodexReady(ui *desktop, marker, resultPath string, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		if ui.observed(marker, 0) {
			return nil
		}
		if status, err := os.ReadFile(resultPath + ".status"); err == nil && strings.TrimSpace(string(status)) != "0" {
			return errors.New("real Codex provider refused the turn; provider output withheld")
		} else if err != nil && !os.IsNotExist(err) {
			return err
		}
		select {
		case err := <-ui.wait:
			return fmt.Errorf("Bee exited while waiting for real Codex readiness: %w", err)
		case <-deadline.C:
			_, _, log := ui.snapshot()
			return fmt.Errorf("timed out waiting for %q\n%s", marker, string(log))
		case <-tick.C:
		}
	}
}

func readActualCodexLaunch(path string) (actualCodexLaunch, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return actualCodexLaunch{}, err
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if len(lines) < 3 || lines[0] == "" || lines[1] == "" {
		return actualCodexLaunch{}, errors.New("malformed real Codex launch report")
	}
	return actualCodexLaunch{Directory: lines[0], Home: lines[1], CodexHome: lines[2], Arguments: lines[3:]}, nil
}

func hasActualCodexResume(arguments []string, expected string) bool {
	for index, argument := range arguments {
		if argument == "resume" && index+1 < len(arguments) && arguments[index+1] == expected {
			return true
		}
	}
	return false
}

func validateActualCodexWindowArguments(arguments []string, expectedResume string) error {
	resumeCount, sandboxCount := 0, 0
	for index, argument := range arguments {
		switch argument {
		case "--":
			return errors.New("real Codex window arguments contained a prompt delimiter")
		case "exec":
			return errors.New("real Codex window arguments bypassed the interactive driver shape")
		case "--sandbox":
			if index+1 >= len(arguments) || arguments[index+1] != "read-only" {
				return errors.New("real Codex window did not retain its admitted read-only sandbox")
			}
			sandboxCount++
		case "resume":
			if index+1 >= len(arguments) || arguments[index+1] != expectedResume {
				return errors.New("real Codex window carried an unexpected resume reference")
			}
			resumeCount++
		}
	}
	if sandboxCount != 1 {
		return errors.New("real Codex window did not carry exactly one admitted sandbox")
	}
	if (expectedResume == "" && resumeCount != 0) || (expectedResume != "" && resumeCount != 1) {
		return errors.New("real Codex window carried the wrong number of resume references")
	}
	return nil
}

func waitActualCodexHooks(state, attemptID, bindingID, sessionID string, required []string, forbidden []string) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		counts, err := recoveryHookCounts(state, attemptID, bindingID, sessionID)
		if err != nil {
			return err
		}
		for _, event := range forbidden {
			if counts[event] > 0 {
				return fmt.Errorf("recovered provider unexpectedly emitted %s", event)
			}
		}
		complete := true
		for _, event := range required {
			complete = complete && counts[event] > 0
		}
		if complete {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("provider hooks did not commit required events %v", required)
}

func actualCodexHookToolCompleted(state, attemptID, bindingID, toolName string) (bool, error) {
	db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return false, err
	}
	defer db.Close()
	rows, err := db.Query("SELECT record_json FROM bee_thread_records WHERE kind='observation' AND source='bee' ORDER BY sequence")
	if err != nil {
		return false, err
	}
	defer rows.Close()
	pre := map[string]bool{}
	post := map[string]bool{}
	failed := map[string]bool{}
	for rows.Next() {
		var encoded string
		if err := rows.Scan(&encoded); err != nil {
			return false, err
		}
		var record map[string]any
		if json.Unmarshal([]byte(encoded), &record) != nil || record["attempt_id"] != attemptID {
			continue
		}
		body, _ := record["body"].(map[string]any)
		data, _ := body["data"].(map[string]any)
		raw, _ := data["payload_json"].(string)
		var payload map[string]any
		if data["event_name"] != "bee.harness.hook" || json.Unmarshal([]byte(raw), &payload) != nil || payload["binding_id"] != bindingID {
			continue
		}
		fields, _ := payload["fields"].(map[string]any)
		toolUseID, _ := fields["tool_use_id"].(string)
		if fields["tool_name"] != toolName || toolUseID == "" {
			continue
		}
		switch payload["event"] {
		case "PreToolUse":
			pre[toolUseID] = true
		case "PostToolUse":
			post[toolUseID] = true
		case "PostToolUseFailure":
			failed[toolUseID] = true
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	for toolUseID := range pre {
		if post[toolUseID] && !failed[toolUseID] {
			return true, nil
		}
	}
	return false, nil
}

func acceptActualCodexExit(path string) error {
	data, err := os.ReadFile(path + ".status")
	if err != nil {
		return errors.New("real Codex exit status missing")
	}
	if strings.TrimSpace(string(data)) != "0" {
		return errors.New("real Codex returned a nonzero exit status")
	}
	return nil
}

func waitActualCodexProcessExit(item recoveryPlacement, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		alive, err := recoveryIdentityAlive(item)
		if err != nil {
			return err
		}
		if !alive {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("real Codex process remained after owner stop")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestActualCodexManagedColdRecovery(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("CODEX_BIN")
	loginFile := os.Getenv("CODEX_LOGIN_FILE")
	configFile := os.Getenv("CODEX_CONFIG_FILE")
	if binary == "" || executable == "" || loginFile == "" || configFile == "" {
		t.Fatal("BEE_BINARY, CODEX_BIN, CODEX_LOGIN_FILE and CODEX_CONFIG_FILE are required")
	}
	if err := actualCodexColdRecovery(binary, executable, loginFile, configFile); err != nil {
		t.Fatal(err)
	}
	t.Log("real Codex recalled an exact token with stable conversation/HOME/application/thread, a fresh attempt and gateway, and no prompt replay")
}

func actualCodexColdRecovery(binary, executable, loginFile, configFile string) (result error) {
	root, err := os.MkdirTemp("", "bee-real-codex-recovery-")
	if err != nil {
		return err
	}
	defer func() {
		cleanupErr := os.RemoveAll(root)
		if cleanupErr == nil {
			if _, statErr := os.Stat(root); statErr != nil && !os.IsNotExist(statErr) {
				cleanupErr = statErr
			} else if statErr == nil {
				cleanupErr = errors.New("temporary Codex root still exists after cleanup")
			}
		}
		if result == nil && cleanupErr != nil {
			result = fmt.Errorf("remove credential-bearing Codex acceptance state: %w", cleanupErr)
		}
	}()
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	for _, dir := range []string{filepath.Join(project, "bin"), state, filepath.Join(home, ".codex")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
	}
	loginBefore, err := os.ReadFile(loginFile)
	if err != nil {
		return errors.New("real Codex login unavailable")
	}
	configBefore, err := os.ReadFile(configFile)
	if err != nil {
		return errors.New("real Codex global configuration unavailable")
	}
	if err := os.WriteFile(filepath.Join(home, ".codex", "auth.json"), loginBefore, 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(home, ".codex", "config.toml"), configBefore, 0600); err != nil {
		return err
	}
	firstReport, secondReport := filepath.Join(root, "first-launch"), filepath.Join(root, "second-launch")
	firstResult, secondResult := filepath.Join(root, "first-result.jsonl"), filepath.Join(root, "second-result.jsonl")
	token := fmt.Sprintf("BEE_CODEX_COLD_%d", time.Now().UnixNano())
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	firstPrompt := "First call the Bee thread_read MCP tool once. Then read fixture.txt without changing any file. Remember its content for a later question. Reply with exactly its content."
	secondPrompt := "What exact token did I ask you to remember earlier? Reply with only that token and do not use tools."
	for phase, prompt := range map[string]string{"first": firstPrompt, "second": secondPrompt} {
		if err := os.WriteFile(filepath.Join(root, phase+"-task"), []byte(prompt), 0600); err != nil {
			return err
		}
	}
	helper, err := os.Executable()
	if err != nil {
		return err
	}
	script := "#!/bin/sh\nexec " + shellQuote(helper) + " " + actualCodexWrapper + " " + shellQuote(executable) + " " + shellQuote(root) + " \"$@\"\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "codex"), []byte(script), 0700); err != nil {
		return err
	}
	projectBefore, err := treeFingerprint(project)
	if err != nil {
		return err
	}
	var first, second *desktop
	var retained *owner
	defer func() {
		var cleanupErr error
		if retained != nil {
			cleanupErr = retained.stop()
		}
		if first != nil {
			first.close()
		}
		if second != nil {
			second.close()
		}
		if err := stopFixtureOwners(binary, state); cleanupErr == nil && err != nil {
			cleanupErr = err
		}
		if result == nil && cleanupErr != nil {
			result = fmt.Errorf("clean real Codex acceptance processes: %w", cleanupErr)
		}
	}()
	first, err = newDesktop(binary, project, state, home)
	if err != nil {
		return err
	}
	if err = first.waitFor("Codex", 25*time.Second); err != nil {
		return err
	}
	if err = first.send("\x1b[B\x1b[B\r"); err != nil {
		return err
	}
	for _, detail := range []string{"Configured folder", "No instructions", "14 tools configured"} {
		if err = first.waitFor(detail, 5*time.Second); err != nil {
			return fmt.Errorf("real Codex profile summary: %w", err)
		}
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	if err = waitActualCodexReady(first, "BEE_RECOVERY_AGENT_READY_first", firstResult, 120*time.Second); err != nil {
		stderr, _ := os.ReadFile(firstResult + ".stderr")
		return fmt.Errorf("real Codex first launch did not become ready (stderr bytes=%d): %w", len(stderr), err)
	}
	firstOutcome, err := readActualCodexResult(firstResult, token, true, false)
	if err != nil {
		return err
	}
	if err := acceptActualCodexExit(firstResult); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(project, "fixture.txt")); err != nil {
		return err
	}
	firstLaunch, err := readActualCodexLaunch(firstReport)
	if err != nil {
		return err
	}
	if firstLaunch.Directory != project || firstLaunch.Home == "" {
		return errors.New("first real Codex launch changed its project or omitted its retained home")
	}
	if err := validateActualCodexWindowArguments(firstLaunch.Arguments, ""); err != nil {
		return err
	}
	if hasActualCodexResume(firstLaunch.Arguments, firstOutcome.ThreadID) || strings.Contains(strings.Join(firstLaunch.Arguments, "\n"), firstPrompt) {
		return errors.New("first real Codex launch carried recovery state or the wrapper task")
	}
	app, saved, err := waitRecoveryWorkspace(state, func(snapshot recoveryWorkspace) (recoveryApplication, recoverySaved, bool) {
		for _, candidate := range snapshot.Applications {
			var decoded recoverySaved
			if candidate.DefinitionID == "bee.harness.window:app" && candidate.ResumeState != "" && json.Unmarshal([]byte(candidate.ResumeState), &decoded) == nil && decoded.PreviousAttemptID != "" && decoded.ThreadID != "" {
				return candidate, decoded, true
			}
		}
		return recoveryApplication{}, recoverySaved{}, false
	}, 30*time.Second)
	if err != nil {
		return err
	}
	if err := assertManagedRoute(state, "codex"); err != nil {
		return err
	}
	placements, err := readRecoveryPlacement(state)
	if err != nil {
		return err
	}
	var old recoveryPlacement
	for _, candidate := range placements {
		if candidate.AttemptID == saved.PreviousAttemptID {
			old = candidate
		}
	}
	if old.AttemptID == "" {
		return errors.New("real Codex checkpoint attempt is absent")
	}
	oldBinding, err := readRecoveryBinding(state, old.AttemptID)
	if err != nil {
		return err
	}
	if err := waitActualCodexHooks(state, old.AttemptID, oldBinding, firstOutcome.ThreadID, []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}, nil); err != nil {
		return err
	}
	completed, err := actualCodexHookToolCompleted(state, old.AttemptID, oldBinding, "mcp__bee__thread_read")
	if err != nil || !completed {
		return fmt.Errorf("real Codex first turn did not complete the Bee thread_read MCP call: completed=%t err=%v", completed, err)
	}
	turns, successes, err := recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Codex first turn invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
	}
	retained, err = ownerChild(first.cmd.Process.Pid, binary, state, 10*time.Second)
	if err != nil {
		return err
	}
	if err = retained.stop(); err != nil {
		return err
	}
	retained = nil
	first.close()
	first = nil
	second, err = newDesktop(binary, project, state, home)
	if err != nil {
		return err
	}
	if err = waitActualCodexReady(second, "BEE_RECOVERY_AGENT_READY_second", secondResult, 120*time.Second); err != nil {
		stderr, _ := os.ReadFile(secondResult + ".stderr")
		return fmt.Errorf("real Codex resumed launch did not become ready (stderr bytes=%d): %w", len(stderr), err)
	}
	secondOutcome, err := readActualCodexResult(secondResult, token, false, true)
	if err != nil {
		return err
	}
	if err := acceptActualCodexExit(secondResult); err != nil {
		return err
	}
	if secondOutcome.ThreadID != firstOutcome.ThreadID {
		return errors.New("real Codex recovery changed conversation identity")
	}
	secondLaunch, err := readActualCodexLaunch(secondReport)
	if err != nil {
		return err
	}
	if secondLaunch.Directory != firstLaunch.Directory || secondLaunch.Home != firstLaunch.Home || secondLaunch.CodexHome != firstLaunch.CodexHome || !hasActualCodexResume(secondLaunch.Arguments, firstOutcome.ThreadID) {
		return errors.New("real Codex recovery changed its project/HOME/CODEX_HOME or omitted its session reference")
	}
	if err := validateActualCodexWindowArguments(secondLaunch.Arguments, firstOutcome.ThreadID); err != nil {
		return err
	}
	if strings.Contains(strings.Join(secondLaunch.Arguments, "\n"), firstPrompt) {
		return errors.New("real Codex recovery replayed the original task prompt")
	}
	newApp, newSaved, err := waitRecoveryWorkspace(state, func(snapshot recoveryWorkspace) (recoveryApplication, recoverySaved, bool) {
		for _, candidate := range snapshot.Applications {
			var decoded recoverySaved
			if candidate.ID == app.ID && candidate.InstanceID == app.InstanceID && candidate.ResumeState != "" && json.Unmarshal([]byte(candidate.ResumeState), &decoded) == nil && decoded.PreviousAttemptID != "" && decoded.PreviousAttemptID != old.AttemptID {
				return candidate, decoded, true
			}
		}
		return recoveryApplication{}, recoverySaved{}, false
	}, 30*time.Second)
	if err != nil {
		return err
	}
	if newApp.ID != app.ID || newApp.InstanceID != app.InstanceID || newSaved.ThreadID != saved.ThreadID {
		return errors.New("real Codex recovery changed application or thread identity")
	}
	if err := assertManagedRoute(state, "codex"); err != nil {
		return err
	}
	newRows, err := readRecoveryPlacement(state)
	if err != nil {
		return err
	}
	var fresh, retired recoveryPlacement
	for _, item := range newRows {
		if item.AttemptID == newSaved.PreviousAttemptID {
			fresh = item
		}
		if item.AttemptID == old.AttemptID {
			retired = item
		}
	}
	if len(newRows) != 2 || retired.Execution != "exited" || retired.Cleanup != "complete" {
		return errors.New("real Codex predecessor did not retire cleanly")
	}
	if fresh.AttemptID == "" || fresh.AttemptID == old.AttemptID || fresh.ActionID != old.ActionID || !recoveryIdentityValid(fresh) {
		return errors.New("real Codex recovery did not create one fresh measured attempt")
	}
	newBinding, err := readRecoveryBinding(state, fresh.AttemptID)
	if err != nil {
		return err
	}
	if newBinding == oldBinding {
		return errors.New("real Codex recovery reused its gateway binding")
	}
	if err := waitActualCodexHooks(state, fresh.AttemptID, newBinding, firstOutcome.ThreadID, []string{"SessionStart", "UserPromptSubmit", "Stop"}, []string{"PreToolUse", "PostToolUse"}); err != nil {
		return err
	}
	turns, successes, err = recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Codex recovery invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
	}
	loginAfter, err := os.ReadFile(loginFile)
	if err != nil || string(loginAfter) != string(loginBefore) {
		return errors.New("real Codex recovery changed the source login")
	}
	configAfter, err := os.ReadFile(configFile)
	if err != nil || string(configAfter) != string(configBefore) {
		return errors.New("real Codex recovery changed the source global configuration")
	}
	retained, err = ownerChild(second.cmd.Process.Pid, binary, state, 10*time.Second)
	if err != nil {
		return err
	}
	second.close()
	second = nil
	if err = retained.stop(); err != nil {
		return err
	}
	retained = nil
	if err := waitActualCodexProcessExit(fresh, 5*time.Second); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	projectAfter, err := treeFingerprint(project)
	if err != nil {
		return err
	}
	if projectAfter != projectBefore {
		return errors.New("real Codex recovery changed the project tree")
	}
	return nil
}
