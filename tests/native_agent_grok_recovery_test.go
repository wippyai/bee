// SPDX-License-Identifier: MIT
// Durable opt-in acceptance for real Grok conversation recovery.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

type actualGrokLaunch struct {
	Directory string
	Home      string
	Arguments []string
}

func readActualGrokLaunch(path string) (actualGrokLaunch, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return actualGrokLaunch{}, err
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) < 2 || lines[0] == "" || lines[1] == "" {
		return actualGrokLaunch{}, errors.New("malformed real Grok launch report")
	}
	return actualGrokLaunch{Directory: lines[0], Home: lines[1], Arguments: lines[2:]}, nil
}

func acceptActualGrokResult(path, expected string, exact bool) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", errors.New("real Grok result missing")
	}
	var value struct {
		SessionID  string `json:"sessionId"`
		Text       string `json:"text"`
		StopReason string `json:"stopReason"`
	}
	if json.Unmarshal(data, &value) != nil {
		return "", errors.New("real Grok emitted malformed JSON")
	}
	answer := strings.TrimSpace(value.Text)
	matched := answer == expected || (!exact && strings.HasSuffix(answer, expected))
	if value.SessionID == "" || value.StopReason != "end_turn" || !matched {
		return "", fmt.Errorf("real Grok result rejected (session=%t, stop=%q, bytes=%d); content withheld", value.SessionID != "", value.StopReason, len(data))
	}
	status, err := os.ReadFile(path + ".status")
	if err != nil || strings.TrimSpace(string(status)) != "0" {
		return "", errors.New("real Grok returned a nonzero exit status")
	}
	return value.SessionID, nil
}

func actualGrokSession(state string) (string, error) {
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
			return "", errors.New("conflicting real Grok conversation identities")
		}
		found = id
	}
	if err := rows.Err(); err != nil {
		return "", err
	}
	if found == "" {
		return "", errors.New("no real Grok hook conversation identity")
	}
	return found, nil
}

func hasActualGrokResume(args []string, expected string) bool {
	for index, arg := range args {
		if (arg == "-r" || arg == "--resume") && index+1 < len(args) && args[index+1] == expected {
			return true
		}
	}
	return false
}

func proveActualGrokToolFreeRecall(state, attemptID, bindingID string) error {
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
			return errors.New("real Grok recall used a tool")
		}
		if stopped {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("real Grok recall Stop observation was not committed")
}

func waitActualGrokProcessExit(item recoveryPlacement, timeout time.Duration) error {
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
			return errors.New("real Grok process remained after owner stop")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func actualGrokCompletedTool(state, attemptID, bindingID, toolName string) (bool, error) {
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
	pre, post, failed := 0, 0, false
	seen := map[string]bool{}
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
		name, _ := fields["tool_name"].(string)
		if name != "" {
			seen[name] = true
		}
		if fields["tool_name"] != toolName {
			continue
		}
		switch payload["event"] {
		case "PreToolUse":
			pre++
		case "PostToolUse":
			post++
			contentSizes, _ := fields["content_sizes"].(map[string]any)
			if size, _ := contentSizes["error_details"].(float64); size > 0 {
				failed = true
			}
		case "PostToolUseFailure":
			failed = true
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	// Grok's command-hook wire does not expose a stable tool_use_id. In this
	// controlled prompt, require balanced exact-name pre/post observations and
	// no reported failure rather than correlating unrelated tool names.
	if pre == 0 || post == 0 {
		names := make([]string, 0, len(seen))
		for name := range seen {
			names = append(names, name)
		}
		sort.Strings(names)
		return false, fmt.Errorf("exact tool %q absent from completed hook pair; observed names=%v", toolName, names)
	}
	if pre != post || failed {
		return false, fmt.Errorf("exact tool %q did not complete cleanly: pre=%d post=%d failed=%t", toolName, pre, post, failed)
	}
	return true, nil
}

func TestActualGrokManagedColdRecovery(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("GROK_BIN")
	loginFile := os.Getenv("GROK_LOGIN_FILE")
	configFile := os.Getenv("GROK_CONFIG_FILE")
	if binary == "" || executable == "" || loginFile == "" || configFile == "" {
		t.Fatal("BEE_BINARY, GROK_BIN, GROK_LOGIN_FILE and GROK_CONFIG_FILE are required")
	}
	if err := actualGrokColdRecovery(binary, executable, loginFile, configFile); err != nil {
		t.Fatal(err)
	}
	t.Log("real Grok recalled an exact token with stable conversation/HOME/application/thread, a fresh attempt and gateway, and no prompt replay")
}

func actualGrokColdRecovery(binary, executable, loginFile, configFile string) (result error) {
	root, err := os.MkdirTemp("", "bee-real-grok-recovery-")
	if err != nil {
		return err
	}
	defer func() {
		cleanupErr := os.RemoveAll(root)
		if cleanupErr == nil {
			if _, statErr := os.Stat(root); statErr != nil && !os.IsNotExist(statErr) {
				cleanupErr = statErr
			} else if statErr == nil {
				cleanupErr = errors.New("temporary Grok root still exists after cleanup")
			}
		}
		if result == nil && cleanupErr != nil {
			result = fmt.Errorf("remove credential-bearing Grok acceptance state: %w", cleanupErr)
		}
	}()
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	for _, dir := range []string{filepath.Join(project, "bin"), state, filepath.Join(home, ".grok")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
	}
	loginBefore, err := os.ReadFile(loginFile)
	if err != nil {
		return errors.New("real Grok login unavailable")
	}
	configBefore, err := os.ReadFile(configFile)
	if err != nil {
		return errors.New("real Grok global configuration unavailable")
	}
	if err := os.WriteFile(filepath.Join(home, ".grok", "auth.json"), loginBefore, 0600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(home, ".grok", "config.toml"), configBefore, 0600); err != nil {
		return err
	}
	firstReport, secondReport := filepath.Join(root, "first-launch"), filepath.Join(root, "second-launch")
	firstResult, secondResult := filepath.Join(root, "first-result.json"), filepath.Join(root, "second-result.json")
	token := fmt.Sprintf("BEE_GROK_COLD_%d", time.Now().UnixNano())
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
	script := "#!/bin/sh\nset -eu\numask 077\nphase=first\nif [ -f \"$HOME/bee-session-proof\" ]; then phase=second; fi\n" +
		"report=" + shellQuote(firstReport) + "\nresult=" + shellQuote(firstResult) + "\ntask=" + shellQuote(filepath.Join(root, "first-task")) + "\n" +
		"if [ \"$phase\" = second ]; then report=" + shellQuote(secondReport) + "; result=" + shellQuote(secondResult) + "; task=" + shellQuote(filepath.Join(root, "second-task")) + "; fi\n" +
		"printf '%s\\n%s\\n' \"$PWD\" \"$HOME\" > \"$report\"\nprintf '%s\\n' \"$@\" >> \"$report\"\n" +
		"set +e\nGROK_DISABLE_AUTOUPDATER=1 " + shellQuote(executable) + " \"$@\" --output-format json --always-approve --max-turns 8 --disable-web-search --no-subagents --prompt-file \"$task\" > \"$result\" 2> \"$result.stderr\"\nstatus=$?\nset -e\nprintf '%s\\n' \"$status\" > \"$result.status\"\n" +
		"printf retained > \"$HOME/bee-session-proof\"\nprintf 'BEE_RECOVERY_AGENT_READY_%s\\n' \"$phase\"\nIFS= read -r answer\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "grok"), []byte(script), 0700); err != nil {
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
			result = fmt.Errorf("clean real Grok acceptance processes: %w", cleanupErr)
		}
	}()
	first, err = newDesktop(binary, project, state, home)
	if err != nil {
		return err
	}
	if err = first.waitFor("Choose a profile", 25*time.Second); err != nil {
		return err
	}
	if err = first.send("\x1b[B\x1b[B\x1b[B\r"); err != nil {
		return err
	}
	for _, detail := range []string{"Configured folder", "No instructions", "5 tools configured"} {
		if err = first.waitFor(detail, 5*time.Second); err != nil {
			return fmt.Errorf("real Grok profile summary: %w", err)
		}
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	if err = first.waitFor("BEE_RECOVERY_AGENT_READY_first", 120*time.Second); err != nil {
		return err
	}
	resultSessionID, err := acceptActualGrokResult(firstResult, token, false)
	if err != nil {
		return err
	}
	var sessionID string
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		sessionID, err = actualGrokSession(state)
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		return err
	}
	if resultSessionID != sessionID {
		return errors.New("real Grok result and hook conversation identities differ")
	}
	if err := os.Remove(filepath.Join(project, "fixture.txt")); err != nil {
		return err
	}
	firstLaunch, err := readActualGrokLaunch(firstReport)
	if err != nil {
		return err
	}
	if firstLaunch.Directory != project {
		return errors.New("first real Grok launch changed its project directory")
	}
	if hasActualGrokResume(firstLaunch.Arguments, sessionID) {
		return errors.New("first real Grok launch unexpectedly carried a resume reference")
	}
	if strings.Contains(strings.Join(firstLaunch.Arguments, "\n"), firstPrompt) {
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
	if err := assertManagedRoute(state, "grok"); err != nil {
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
		return errors.New("real Grok checkpoint attempt is absent")
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
		if hookCounts["SessionStart"] > 0 && hookCounts["UserPromptSubmit"] > 0 && hookCounts["PreToolUse"] > 0 && hookCounts["PostToolUse"] > 0 && hookCounts["Stop"] > 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	for _, event := range []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"} {
		if hookCounts[event] == 0 {
			return fmt.Errorf("real Grok first turn omitted %s hook", event)
		}
	}
	completedBeeRead, err := actualGrokCompletedTool(state, old.AttemptID, oldBinding, "bee__thread_read")
	if err != nil || !completedBeeRead {
		return fmt.Errorf("real Grok first turn did not complete Bee thread_read: completed=%t err=%v", completedBeeRead, err)
	}
	completedSourceRead, err := actualGrokCompletedTool(state, old.AttemptID, oldBinding, "read_file")
	if err != nil || !completedSourceRead {
		return fmt.Errorf("real Grok first turn did not complete fixture.txt through read_file: completed=%t err=%v", completedSourceRead, err)
	}
	turns, successes, err := recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Grok first turn invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
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
	secondResultSessionID, err := acceptActualGrokResult(secondResult, token, true)
	if err != nil {
		return err
	}
	if secondResultSessionID != sessionID {
		return errors.New("real Grok recovery changed its result conversation identity")
	}
	secondLaunch, err := readActualGrokLaunch(secondReport)
	if err != nil {
		return err
	}
	if secondLaunch.Directory != firstLaunch.Directory || secondLaunch.Home != firstLaunch.Home || !hasActualGrokResume(secondLaunch.Arguments, sessionID) {
		return errors.New("real Grok recovery changed its project/HOME or omitted its conversation reference")
	}
	if strings.Contains(strings.Join(secondLaunch.Arguments, "\n"), firstPrompt) {
		return errors.New("real Grok recovery replayed the original task prompt")
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
		return errors.New("real Grok recovery changed application or thread identity")
	}
	if err := assertManagedRoute(state, "grok"); err != nil {
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
		return errors.New("real Grok predecessor did not retire cleanly")
	}
	if fresh.AttemptID == "" || fresh.AttemptID == old.AttemptID || fresh.ActionID != old.ActionID {
		return errors.New("real Grok recovery did not create one fresh attempt")
	}
	if !recoveryIdentityValid(fresh) {
		return errors.New("real Grok replacement has no complete native identity")
	}
	newBinding, err := readRecoveryBinding(state, fresh.AttemptID)
	if err != nil {
		return err
	}
	if newBinding == oldBinding {
		return errors.New("real Grok recovery reused its gateway binding")
	}
	if err := proveActualGrokToolFreeRecall(state, fresh.AttemptID, newBinding); err != nil {
		return err
	}
	turns, successes, err = recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Grok recovery invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
	}
	loginAfter, err := os.ReadFile(loginFile)
	if err != nil || string(loginAfter) != string(loginBefore) {
		return errors.New("real Grok recovery changed the source login")
	}
	configAfter, err := os.ReadFile(configFile)
	if err != nil || string(configAfter) != string(configBefore) {
		return errors.New("real Grok recovery changed the source global configuration")
	}
	if _, err := os.Stat(filepath.Join(project, ".grok")); !os.IsNotExist(err) {
		return errors.New("real Grok recovery wrote provider configuration into the project")
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
	if err := waitActualGrokProcessExit(fresh, 5*time.Second); err != nil {
		return err
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
		return errors.New("real Grok recovery changed the project tree")
	}
	return nil
}
