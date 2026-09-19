// SPDX-License-Identifier: MIT
// Durable opt-in acceptance for real Claude Code conversation recovery.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type actualClaudeResult struct {
	Type      string `json:"type"`
	Subtype   string `json:"subtype"`
	IsError   bool   `json:"is_error"`
	Result    string `json:"result"`
	SessionID string `json:"session_id"`
}

func readActualClaudeResult(path, expected string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("real Claude result missing")
	}
	var value actualClaudeResult
	if json.Unmarshal(data, &value) != nil || value.Type != "result" || value.Subtype != "success" || value.IsError ||
		strings.TrimSpace(value.Result) != expected || value.SessionID == "" {
		return "", fmt.Errorf("real Claude result rejected (type=%q, subtype=%q, error=%t, bytes=%d); content withheld", value.Type, value.Subtype, value.IsError, len(data))
	}
	return value.SessionID, nil
}

func waitRecoveryHooks(state, attemptID, bindingID, sessionID string, required []string, forbidden []string) error {
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

func recoveryHookToolCompleted(state, attemptID, bindingID, toolName string) (bool, error) {
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

func acceptActualClaudeExit(path string) error {
	data, err := os.ReadFile(path + ".status")
	if err != nil {
		return errors.New("real Claude exit status missing")
	}
	if strings.TrimSpace(string(data)) != "0" {
		return errors.New("real Claude returned a nonzero exit status")
	}
	return nil
}

func waitActualClaudeReady(ui *desktop, marker, resultPath string, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	for {
		if ui.observed(marker, 0) {
			return nil
		}
		data, err := os.ReadFile(resultPath)
		if err == nil {
			var value actualClaudeResult
			if json.Unmarshal(data, &value) == nil && value.Type == "result" && value.IsError {
				return fmt.Errorf("real Claude provider refused the turn (subtype=%q, result bytes=%d)", value.Subtype, len(value.Result))
			}
		} else if !os.IsNotExist(err) {
			return err
		}
		select {
		case err := <-ui.wait:
			return fmt.Errorf("Bee exited while waiting for real Claude readiness: %w", err)
		case <-deadline.C:
			_, _, log := ui.snapshot()
			return fmt.Errorf("timed out waiting for %q\n%s", marker, string(log))
		case <-tick.C:
		}
	}
}

func TestActualClaudeManagedColdRecovery(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("CLAUDE_BIN")
	credentialEnv := os.Getenv("CLAUDE_CREDENTIAL_ENV")
	if binary == "" || executable == "" || credentialEnv == "" {
		t.Fatal("BEE_BINARY, CLAUDE_BIN and CLAUDE_CREDENTIAL_ENV are required")
	}
	if credentialEnv != "ANTHROPIC_API_KEY" {
		t.Fatal("CLAUDE_CREDENTIAL_ENV must select ANTHROPIC_API_KEY")
	}
	credential, present := os.LookupEnv(credentialEnv)
	if !present || credential == "" || len(credential) > 8192 || strings.ContainsAny(credential, "\x00\r\n") {
		t.Fatal("selected Claude credential environment variable is absent or invalid")
	}
	if err := actualClaudeColdRecovery(binary, executable, credentialEnv, credential); err != nil {
		t.Fatal(err)
	}
	t.Log("real Claude recalled an exact token with stable conversation/HOME/application/thread, a fresh attempt and gateway, and no prompt replay")
}

func actualClaudeColdRecovery(binary, executable, credentialEnv, credential string) (result error) {
	root, err := os.MkdirTemp("", "bee-real-claude-recovery-")
	if err != nil {
		return err
	}
	defer func() {
		cleanupErr := os.RemoveAll(root)
		if cleanupErr == nil {
			if _, statErr := os.Stat(root); statErr != nil && !os.IsNotExist(statErr) {
				cleanupErr = statErr
			} else if statErr == nil {
				cleanupErr = errors.New("temporary Claude root still exists after cleanup")
			}
		}
		if result == nil && cleanupErr != nil {
			result = fmt.Errorf("remove credential-bearing Claude acceptance state: %w", cleanupErr)
		}
	}()
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	for _, dir := range []string{filepath.Join(project, "bin"), state, home} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
	}
	firstReport, secondReport := filepath.Join(root, "first-launch"), filepath.Join(root, "second-launch")
	firstResult, secondResult := filepath.Join(root, "first-result.json"), filepath.Join(root, "second-result.json")
	token := fmt.Sprintf("BEE_CLAUDE_COLD_%d", time.Now().UnixNano())
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	firstPrompt := "First call mcp__bee__thread_read once. Then read fixture.txt using the Read tool. Remember its content for a later question. Reply with exactly its content. Do not run commands or write files."
	secondPrompt := "What exact token did I ask you to remember earlier? Reply with only that token and do not use tools."
	script := "#!/bin/sh\nset -eu\numask 077\nphase=first\nif [ -f \"$HOME/bee-session-proof\" ]; then phase=second; fi\n" +
		"report=" + shellQuote(firstReport) + "\nresult=" + shellQuote(firstResult) + "\ntask=" + shellQuote(firstPrompt) + "\n" +
		"if [ \"$phase\" = second ]; then report=" + shellQuote(secondReport) + "; result=" + shellQuote(secondResult) + "; task=" + shellQuote(secondPrompt) + "; fi\n" +
		"printf '%s\\n%s\\n' \"$PWD\" \"$HOME\" > \"$report\"\nprintf '%s\\n' \"$@\" >> \"$report\"\n" +
		"set +e\n" + shellQuote(executable) + " \"$@\" -p --output-format json -- \"$task\" > \"$result\" 2> \"$result.stderr\"\nstatus=$?\nset -e\nprintf '%s\\n' \"$status\" > \"$result.status\"\n" +
		"printf retained > \"$HOME/bee-session-proof\"\nprintf 'BEE_RECOVERY_AGENT_READY_%s\\n' \"$phase\"\nIFS= read -r answer\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "claude"), []byte(script), 0700); err != nil {
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
			result = fmt.Errorf("clean real Claude acceptance processes: %w", cleanupErr)
		}
	}()
	first, err = newDesktop(binary, project, state, home, credentialEnv+"="+credential)
	if err != nil {
		return err
	}
	if err = first.waitFor("Claude", 25*time.Second); err != nil {
		return err
	}
	if err = first.send("\x1b[B\r"); err != nil {
		return err
	}
	for _, detail := range []string{"Configured folder", "No instructions", "7 tools configured"} {
		if err = first.waitFor(detail, 5*time.Second); err != nil {
			return fmt.Errorf("real Claude profile summary: %w", err)
		}
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	if err = waitActualClaudeReady(first, "BEE_RECOVERY_AGENT_READY_first", firstResult, 120*time.Second); err != nil {
		stderr, _ := os.ReadFile(firstResult + ".stderr")
		return fmt.Errorf("real Claude first launch did not become ready (stderr bytes=%d): %w", len(stderr), err)
	}
	sessionID, err := readActualClaudeResult(firstResult, token)
	if err != nil {
		return err
	}
	if err := acceptActualClaudeExit(firstResult); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(project, "fixture.txt")); err != nil {
		return err
	}
	args, childHome, err := recoveryArgs(firstReport)
	if err != nil {
		return err
	}
	if hasRecoveryResume(args, sessionID) || strings.Contains(strings.Join(args, "\n"), firstPrompt) {
		return errors.New("first real Claude launch carried recovery state or the wrapper task")
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
	if err := assertManagedRoute(state, "claude"); err != nil {
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
		return errors.New("real Claude checkpoint attempt is absent")
	}
	oldBinding, err := readRecoveryBinding(state, old.AttemptID)
	if err != nil {
		return err
	}
	if err := waitRecoveryHooks(state, old.AttemptID, oldBinding, sessionID, []string{"SessionStart", "PreToolUse", "PostToolUse", "Stop"}, nil); err != nil {
		return err
	}
	for _, toolName := range []string{"mcp__bee__thread_read", "Read"} {
		completed, err := recoveryHookToolCompleted(state, old.AttemptID, oldBinding, toolName)
		if err != nil || !completed {
			return fmt.Errorf("real Claude first turn did not complete %s: completed=%t err=%v", toolName, completed, err)
		}
	}
	turns, successes, err := recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Claude first turn invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
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
	second, err = newDesktop(binary, project, state, home, credentialEnv+"="+credential)
	if err != nil {
		return err
	}
	if err = waitActualClaudeReady(second, "BEE_RECOVERY_AGENT_READY_second", secondResult, 120*time.Second); err != nil {
		stderr, _ := os.ReadFile(secondResult + ".stderr")
		return fmt.Errorf("real Claude resumed launch did not become ready (stderr bytes=%d): %w", len(stderr), err)
	}
	secondSessionID, err := readActualClaudeResult(secondResult, token)
	if err != nil {
		return err
	}
	if err := acceptActualClaudeExit(secondResult); err != nil {
		return err
	}
	if secondSessionID != sessionID {
		return errors.New("real Claude recovery changed conversation identity")
	}
	secondArgs, secondHome, err := recoveryArgs(secondReport)
	if err != nil {
		return err
	}
	if secondHome != childHome || !hasRecoveryResume(secondArgs, sessionID) {
		return errors.New("real Claude recovery changed HOME or omitted its session reference")
	}
	if strings.Contains(strings.Join(secondArgs, "\n"), firstPrompt) {
		return errors.New("real Claude recovery replayed the original task prompt")
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
		return errors.New("real Claude recovery changed application or thread identity")
	}
	if err := assertManagedRoute(state, "claude"); err != nil {
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
		return errors.New("real Claude predecessor did not retire cleanly")
	}
	if fresh.AttemptID == "" || fresh.AttemptID == old.AttemptID || fresh.ActionID != old.ActionID || !recoveryIdentityValid(fresh) {
		return errors.New("real Claude recovery did not create one fresh measured attempt")
	}
	newBinding, err := readRecoveryBinding(state, fresh.AttemptID)
	if err != nil {
		return err
	}
	if newBinding == oldBinding {
		return errors.New("real Claude recovery reused its gateway binding")
	}
	if err := waitRecoveryHooks(state, fresh.AttemptID, newBinding, sessionID, []string{"SessionStart", "Stop"}, []string{"PreToolUse", "PostToolUse"}); err != nil {
		return err
	}
	turns, successes, err = recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Claude recovery invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
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
	alive, err := recoveryIdentityAlive(fresh)
	if err != nil || alive {
		return fmt.Errorf("real Claude process remained after owner stop: alive=%t err=%v", alive, err)
	}
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	projectAfter, err := treeFingerprint(project)
	if err != nil {
		return err
	}
	if projectAfter != projectBefore {
		return errors.New("real Claude recovery changed the project tree")
	}
	leaked, leakErr := firstFileContaining(root, []byte(credential))
	if leakErr != nil {
		return leakErr
	}
	if leaked != "" {
		return fmt.Errorf("real Claude credential persisted under disposable state in %s", leaked)
	}
	return nil
}

func firstFileContaining(root string, needle []byte) (string, error) {
	var found string
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if found != "" || !entry.Type().IsRegular() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if bytes.Contains(data, needle) {
			found, _ = filepath.Rel(root, path)
		}
		return nil
	})
	return found, err
}
