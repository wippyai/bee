// SPDX-License-Identifier: MIT
// Durable opt-in acceptance for real Agy conversation recovery.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func acceptActualAgyResult(path, expected string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return errors.New("real Agy result missing")
	}
	var value struct {
		Status   string `json:"status"`
		Response string `json:"response"`
	}
	if json.Unmarshal(data, &value) != nil || value.Status != "SUCCESS" || strings.TrimSpace(value.Response) != expected {
		return fmt.Errorf("real Agy result rejected (status=%q, bytes=%d); content withheld", value.Status, len(data))
	}
	return nil
}

func actualAgySession(state string) (string, error) {
	db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return "", err
	}
	defer db.Close()
	rows, err := db.Query("SELECT record_json FROM bee_thread_records WHERE kind='observation' AND source='bee' ORDER BY sequence")
	if err != nil {
		return "", err
	}
	defer rows.Close()
	found := ""
	for rows.Next() {
		var encoded string
		if err := rows.Scan(&encoded); err != nil {
			return "", err
		}
		var record map[string]any
		if json.Unmarshal([]byte(encoded), &record) != nil {
			continue
		}
		body, _ := record["body"].(map[string]any)
		data, _ := body["data"].(map[string]any)
		if data["event_name"] != "bee.harness.hook" {
			continue
		}
		payloadText, _ := data["payload_json"].(string)
		var payload map[string]any
		if json.Unmarshal([]byte(payloadText), &payload) != nil {
			continue
		}
		fields, _ := payload["fields"].(map[string]any)
		id, _ := fields["session_id"].(string)
		if id == "" {
			continue
		}
		if found != "" && found != id {
			return "", errors.New("conflicting real Agy conversation identities")
		}
		found = id
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	if found == "" {
		return "", errors.New("no real Agy hook conversation identity")
	}
	return found, nil
}

func hasActualAgyResume(args []string, expected string) bool {
	for index, arg := range args {
		if arg == "--conversation" && index+1 < len(args) && args[index+1] == expected {
			return true
		}
	}
	return false
}

func proveActualAgyToolFreeRecall(state, attemptID, bindingID string) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
		if err != nil {
			return err
		}
		rows, err := db.Query("SELECT record_json FROM bee_thread_records WHERE kind='observation' AND source='bee' ORDER BY sequence")
		if err != nil {
			db.Close()
			return err
		}
		stopped, usedTool := false, false
		for rows.Next() {
			var encoded string
			if err := rows.Scan(&encoded); err != nil {
				rows.Close()
				db.Close()
				return err
			}
			var record map[string]any
			if json.Unmarshal([]byte(encoded), &record) != nil || record["attempt_id"] != attemptID {
				continue
			}
			body, _ := record["body"].(map[string]any)
			data, _ := body["data"].(map[string]any)
			if data["event_name"] != "bee.harness.hook" {
				continue
			}
			raw, _ := data["payload_json"].(string)
			var payload map[string]any
			if json.Unmarshal([]byte(raw), &payload) != nil || payload["binding_id"] != bindingID {
				continue
			}
			if payload["event"] == "PreToolUse" || payload["event"] == "PostToolUse" {
				usedTool = true
			}
			if payload["event"] == "Stop" {
				stopped = true
			}
		}
		err = rows.Err()
		rows.Close()
		db.Close()
		if err != nil {
			return err
		}
		if usedTool {
			return errors.New("real Agy recall used a tool")
		}
		if stopped {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("real Agy recall Stop observation was not committed")
}

func TestActualAgyManagedColdRecovery(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("AGY_BIN")
	loginFile := os.Getenv("AGY_LOGIN_FILE")
	if binary == "" || executable == "" || loginFile == "" {
		t.Fatal("BEE_BINARY, AGY_BIN and AGY_LOGIN_FILE are required")
	}
	model := os.Getenv("AGY_MODEL")
	if model == "" {
		model = "gemini-3.8-flash"
	}
	if err := actualAgyColdRecovery(binary, executable, loginFile, model); err != nil {
		t.Fatal(err)
	}
	t.Log("real Agy recalled an exact token with stable conversation/HOME/application/thread, a fresh attempt and gateway, and no prompt replay")
}

func actualAgyColdRecovery(binary, executable, loginFile, model string) (result error) {
	root, err := os.MkdirTemp("", "bee-real-agy-recovery-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	for _, dir := range []string{filepath.Join(project, "bin"), state, home} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
	}
	loginBefore, err := os.ReadFile(loginFile)
	if err != nil {
		return errors.New("real Agy login unavailable")
	}
	authDir := filepath.Join(home, ".gemini", "antigravity-cli")
	if err := os.MkdirAll(authDir, 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(authDir, "antigravity-oauth-token"), loginBefore, 0600); err != nil {
		return err
	}
	firstReport, secondReport := filepath.Join(root, "first-launch"), filepath.Join(root, "second-launch")
	firstResult, secondResult := filepath.Join(root, "first-result.json"), filepath.Join(root, "second-result.json")
	token := fmt.Sprintf("BEE_AGY_COLD_%d", time.Now().UnixNano())
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	script := "#!/bin/sh\nset -eu\numask 077\nphase=first\nif [ -f \"$HOME/bee-session-proof\" ]; then phase=second; fi\n" +
		"report=" + shellQuote(firstReport) + "\nresult=" + shellQuote(firstResult) + "\n" +
		"task='Read fixture.txt using view_file. Remember its content for a later question. Reply with exactly its content. Do not run commands or write files.'\n" +
		"if [ \"$phase\" = second ]; then report=" + shellQuote(secondReport) + "; result=" + shellQuote(secondResult) + "; task='What exact token did you read earlier in this conversation? Reply with only that token. Do not use any tools.'; fi\n" +
		"printf '%s\\n%s\\n' \"$PWD\" \"$HOME\" > \"$report\"\nprintf '%s\\n' \"$@\" >> \"$report\"\n" +
		"AGY_CLI_DISABLE_AUTO_UPDATE=1 " + shellQuote(executable) + " \"$@\" --output-format json --model " + shellQuote(model) + " --effort high --print-timeout 90s -p \"$task\" > \"$result\" 2> \"$result.stderr\"\n" +
		"printf retained > \"$HOME/bee-session-proof\"\nprintf 'BEE_RECOVERY_AGENT_READY_%s\\n' \"$phase\"\nIFS= read -r answer\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "agy"), []byte(script), 0700); err != nil {
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
			result = fmt.Errorf("clean real Agy acceptance processes: %w", cleanupErr)
		}
	}()
	first, err = newDesktop(binary, project, state, home)
	if err != nil {
		return err
	}
	if err = first.waitFor("Antigravity", 25*time.Second); err != nil {
		return err
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	for _, detail := range []string{"Configured folder", "No instructions", "9 tools configured"} {
		if err = first.waitFor(detail, 5*time.Second); err != nil {
			return fmt.Errorf("real Agy profile summary: %w", err)
		}
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	if err = first.waitFor("BEE_RECOVERY_AGENT_READY_first", 120*time.Second); err != nil {
		return err
	}
	if err = acceptActualAgyResult(firstResult, token); err != nil {
		return err
	}
	var sessionID string
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		sessionID, err = actualAgySession(state)
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(project, "fixture.txt")); err != nil {
		return err
	}
	args, childHome, err := recoveryArgs(firstReport)
	if err != nil {
		return err
	}
	if hasActualAgyResume(args, sessionID) {
		return errors.New("first real Agy launch unexpectedly carried a resume reference")
	}
	if strings.Contains(strings.Join(args, "\n"), "Read fixture.txt") {
		return errors.New("Bee supplied the wrapper's first task prompt")
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
	if err := assertManagedRoute(state, "agy"); err != nil {
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
		return errors.New("real Agy checkpoint attempt is absent")
	}
	oldBinding, err := readRecoveryBinding(state, old.AttemptID)
	if err != nil {
		return err
	}
	var hookCounts map[string]int
	hookDeadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(hookDeadline) {
		hookCounts, err = recoveryHookCounts(state, old.AttemptID, oldBinding, sessionID)
		if err != nil {
			return err
		}
		if hookCounts["PreToolUse"] > 0 && hookCounts["PostToolUse"] > 0 && hookCounts["Stop"] > 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	for _, event := range []string{"PreToolUse", "PostToolUse", "Stop"} {
		if hookCounts[event] == 0 {
			return fmt.Errorf("real Agy first turn omitted %s hook", event)
		}
	}
	turns, successes, err := recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Agy first turn invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
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
	if err = second.waitFor("BEE_RECOVERY_AGENT_READY_second", 120*time.Second); err != nil {
		return err
	}
	if err = acceptActualAgyResult(secondResult, token); err != nil {
		return err
	}
	secondArgs, secondHome, err := recoveryArgs(secondReport)
	if err != nil {
		return err
	}
	if secondHome != childHome || !hasActualAgyResume(secondArgs, sessionID) {
		return errors.New("real Agy recovery changed HOME or omitted its conversation reference")
	}
	if strings.Contains(strings.Join(secondArgs, "\n"), "Read fixture.txt") {
		return errors.New("real Agy recovery replayed the original task prompt")
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
		return errors.New("real Agy recovery changed application or thread identity")
	}
	if err := assertManagedRoute(state, "agy"); err != nil {
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
		return errors.New("real Agy predecessor did not retire cleanly")
	}
	if fresh.AttemptID == "" || fresh.AttemptID == old.AttemptID || fresh.ActionID != old.ActionID {
		return errors.New("real Agy recovery did not create one fresh attempt")
	}
	if !recoveryIdentityValid(fresh) {
		return errors.New("real Agy replacement has no complete native identity")
	}
	newBinding, err := readRecoveryBinding(state, fresh.AttemptID)
	if err != nil {
		return err
	}
	if newBinding == oldBinding {
		return errors.New("real Agy recovery reused its gateway binding")
	}
	if err := proveActualAgyToolFreeRecall(state, fresh.AttemptID, newBinding); err != nil {
		return err
	}
	turns, successes, err = recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Agy recovery invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
	}
	loginAfter, err := os.ReadFile(loginFile)
	if err != nil || string(loginAfter) != string(loginBefore) {
		return errors.New("real Agy recovery changed the source login")
	}
	if _, err := os.Stat(filepath.Join(project, ".agents")); !os.IsNotExist(err) {
		return errors.New("real Agy recovery wrote provider configuration into the project")
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
	if err != nil {
		return err
	}
	if alive {
		return errors.New("real Agy process remained alive after final owner stop")
	}
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	projectAfter, err := treeFingerprint(project)
	if removeErr := os.Remove(filepath.Join(project, "fixture.txt")); err == nil && removeErr != nil {
		err = removeErr
	}
	if err != nil {
		return err
	}
	if projectAfter != projectBefore {
		return errors.New("real Agy recovery changed the project tree")
	}
	return nil
}
