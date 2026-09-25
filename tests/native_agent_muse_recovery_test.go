// SPDX-License-Identifier: MIT
// Durable opt-in acceptance for real Muse conversation recovery.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

type actualMuseLaunch struct {
	Directory     string
	Home          string
	XDGUnset      bool
	BeeArguments  []string
	ExecArguments []string
}

type actualMuseOutcome struct {
	SessionID     string
	Answer        string
	Terminal      string
	TerminalCount int
}

func readActualMuseLaunch(path string) (actualMuseLaunch, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return actualMuseLaunch{}, err
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if len(lines) < 5 || lines[0] == "" || lines[1] == "" {
		return actualMuseLaunch{}, errors.New("malformed real Muse launch report")
	}
	if lines[2] != "xdg-config-home-unset" {
		return actualMuseLaunch{}, errors.New("real Muse launch inherited XDG_CONFIG_HOME")
	}
	beeMarker, execMarker := -1, -1
	for index, line := range lines[3:] {
		switch line {
		case "bee-args":
			beeMarker = index + 3
		case "exec-args":
			execMarker = index + 3
		}
	}
	if beeMarker < 0 || execMarker <= beeMarker {
		return actualMuseLaunch{}, errors.New("real Muse launch report omitted argument sections")
	}
	arguments := func(start, end int) []string {
		result := make([]string, 0, end-start-1)
		for _, line := range lines[start+1 : end] {
			if line != "" {
				result = append(result, line)
			}
		}
		return result
	}
	return actualMuseLaunch{
		Directory:     lines[0],
		Home:          lines[1],
		XDGUnset:      true,
		BeeArguments:  arguments(beeMarker, execMarker),
		ExecArguments: arguments(execMarker, len(lines)),
	}, nil
}

const museGlobalSettings = `{"schema_version":1,"provider":"meta","model":"muse-spark-1.3-contributor","tui":{"foreign_context_notice_shown":true},"mcpServers":{"user_fixture":{"url":"http://127.0.0.1:9/mcp"}},"hooks":{"PreToolUse":[{"matcher":"read_file","hooks":[{"type":"command","command":"printf user-pre-sentinel","timeout":10}]}]}}
`

var museSelectedHookEvents = []string{"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}

func decodeMuseSettings(path string) (map[string]json.RawMessage, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, err
	}
	return document, nil
}

func equalMuseJSON(left, right json.RawMessage) bool {
	var leftValue, rightValue any
	if json.Unmarshal(left, &leftValue) != nil || json.Unmarshal(right, &rightValue) != nil {
		return false
	}
	return reflect.DeepEqual(leftValue, rightValue)
}

func museHookCommand(group json.RawMessage, needle string) bool {
	var value struct {
		Hooks []struct {
			Type    string `json:"type"`
			Command string `json:"command"`
		} `json:"hooks"`
	}
	if json.Unmarshal(group, &value) != nil {
		return false
	}
	for _, hook := range value.Hooks {
		if hook.Type == "command" && strings.Contains(hook.Command, needle) {
			return true
		}
	}
	return false
}

func museHookTokenPath(home, attemptID string) string {
	digest := sha256.Sum256([]byte("muse-hook\n" + attemptID))
	return filepath.Join(home, ".config", "muse", ".bee-hooks", fmt.Sprintf("%x.json", digest))
}

func readMuseHookToken(path string) ([]byte, string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, "", err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return nil, "", errors.New("Muse hook credential is not a private regular file")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	var document struct {
		Token string `json:"token"`
	}
	if json.Unmarshal(data, &document) != nil || document.Token == "" || len(document.Token) > 4096 {
		return nil, "", errors.New("Muse hook credential file is malformed")
	}
	return data, document.Token, nil
}

func assertMuseHookTokenSource(home, attemptID string) ([]byte, string, error) {
	path := museHookTokenPath(home, attemptID)
	file, token, err := readMuseHookToken(path)
	if err != nil {
		return nil, "", fmt.Errorf("read Muse hook credential: %w", err)
	}
	settings, err := os.ReadFile(filepath.Join(home, ".config", "muse", "settings.json"))
	if err != nil {
		return nil, "", err
	}
	text := string(settings)
	if !strings.Contains(text, "@"+path) {
		return nil, "", errors.New("Muse hooks do not name their attempt credential file")
	}
	if strings.Contains(text, token) || strings.Contains(text, "BEE_GATEWAY_HOOK_TOKEN") {
		return nil, "", errors.New("Muse settings expose the hook credential or its environment source")
	}
	return file, path, nil
}

func museHookGroups(document map[string]json.RawMessage, event string) ([]json.RawMessage, error) {
	raw, ok := document["hooks"]
	if !ok {
		return nil, errors.New("Muse settings omitted hooks")
	}
	var hooks map[string]json.RawMessage
	if err := json.Unmarshal(raw, &hooks); err != nil {
		return nil, err
	}
	var groups []json.RawMessage
	if err := json.Unmarshal(hooks[event], &groups); err != nil {
		return nil, err
	}
	return groups, nil
}

func assertMuseSettings(retainedHome string, globalSettings, login []byte) error {
	root := filepath.Join(retainedHome, ".config", "muse")
	snapshot, err := os.ReadFile(filepath.Join(root, ".bee-global-settings.json"))
	if err != nil {
		return fmt.Errorf("read retained Muse global settings snapshot: %w", err)
	}
	if !bytes.Equal(snapshot, globalSettings) {
		return errors.New("retained Muse global settings snapshot changed")
	}
	auth, err := os.ReadFile(filepath.Join(root, "auth.json"))
	if err != nil || !bytes.Equal(auth, login) {
		return errors.New("retained Muse auth projection differs from the selected login")
	}
	document, err := decodeMuseSettings(filepath.Join(root, "settings.json"))
	if err != nil {
		return fmt.Errorf("decode retained Muse settings: %w", err)
	}
	globalDocument, err := decodeMuseSettings(filepath.Join(root, ".bee-global-settings.json"))
	if err != nil {
		return fmt.Errorf("decode Muse settings snapshot: %w", err)
	}
	for _, field := range []string{"schema_version", "provider", "model", "tui"} {
		globalValue, globalOK := globalDocument[field]
		documentValue, documentOK := document[field]
		if !globalOK || !documentOK || !equalMuseJSON(globalValue, documentValue) {
			return fmt.Errorf("retained Muse settings changed user field %s", field)
		}
	}
	globalServers := map[string]json.RawMessage{}
	if err := json.Unmarshal(globalDocument["mcpServers"], &globalServers); err != nil {
		return err
	}
	servers := map[string]json.RawMessage{}
	if err := json.Unmarshal(document["mcpServers"], &servers); err != nil {
		return fmt.Errorf("decode retained Muse MCP servers: %w", err)
	}
	if len(globalServers) != 1 || len(servers) != 2 {
		return errors.New("retained Muse MCP composition has the wrong server count")
	}
	userServer, userOK := globalServers["user_fixture"]
	composedUserServer, composedUserOK := servers["user_fixture"]
	if !userOK || !composedUserOK || !equalMuseJSON(userServer, composedUserServer) {
		return errors.New("retained Muse global MCP server changed")
	}
	beeServer, ok := servers["bee"]
	if !ok {
		return errors.New("retained Muse settings omitted the Bee MCP server")
	}
	var bee struct {
		URL     string            `json:"url"`
		Headers map[string]string `json:"headers"`
	}
	if json.Unmarshal(beeServer, &bee) != nil || bee.URL == "" || !strings.HasPrefix(bee.Headers["Authorization"], "Bearer ") || strings.Contains(bee.Headers["Authorization"], "${") {
		return errors.New("retained Muse Bee MCP server is not materialized")
	}
	for _, event := range museSelectedHookEvents {
		groups, groupsErr := museHookGroups(document, event)
		if groupsErr != nil {
			return fmt.Errorf("retained Muse %s hooks: %w", event, groupsErr)
		}
		beeGroups := 0
		for _, group := range groups {
			if museHookCommand(group, "hook-post") {
				beeGroups++
			}
		}
		if beeGroups != 1 {
			return fmt.Errorf("retained Muse %s has %d Bee hook groups, want one", event, beeGroups)
		}
	}
	preToolGroups, err := museHookGroups(document, "PreToolUse")
	if err != nil {
		return err
	}
	userSentinel := false
	for _, group := range preToolGroups {
		userSentinel = userSentinel || museHookCommand(group, "user-pre-sentinel")
	}
	if !userSentinel {
		return errors.New("retained Muse PreToolUse hook lost the user sentinel")
	}
	return nil
}

func acceptActualMuseResult(path, expected string, exact bool) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", errors.New("real Muse result missing")
	}
	defer file.Close()

	outcome := actualMuseOutcome{}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	lines := 0
	for scanner.Scan() {
		lines++
		var envelope struct {
			Stream struct {
				ID string `json:"id"`
			} `json:"stream"`
			PayloadType string `json:"payload_type"`
			Payload     struct {
				Text     string `json:"text"`
				Terminal string `json:"terminal"`
			} `json:"payload"`
		}
		if json.Unmarshal(scanner.Bytes(), &envelope) != nil {
			return "", errors.New("real Muse emitted malformed JSONL")
		}
		if envelope.Stream.ID != "" {
			if outcome.SessionID != "" && outcome.SessionID != envelope.Stream.ID {
				return "", errors.New("real Muse changed conversation identity within one turn")
			}
			outcome.SessionID = envelope.Stream.ID
		}
		switch envelope.PayloadType {
		case "run.output.delta":
			outcome.Answer += envelope.Payload.Text
		case "run.terminal.completed":
			outcome.TerminalCount++
			outcome.Terminal = envelope.Payload.Terminal
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	answer := strings.TrimSpace(outcome.Answer)
	matched := answer == expected || (!exact && strings.HasSuffix(answer, expected))
	if outcome.SessionID == "" || outcome.TerminalCount != 1 || outcome.Terminal != "completed" || !matched {
		return "", fmt.Errorf("real Muse result rejected (lines=%d, session=%t, terminals=%d, terminal=%q, answer bytes=%d); content withheld", lines, outcome.SessionID != "", outcome.TerminalCount, outcome.Terminal, len(outcome.Answer))
	}
	return outcome.SessionID, nil
}

func acceptActualMuseExit(path string) error {
	data, err := os.ReadFile(path + ".status")
	if err != nil {
		return errors.New("real Muse exit status missing")
	}
	if strings.TrimSpace(string(data)) != "0" {
		return errors.New("real Muse returned a nonzero exit status")
	}
	return nil
}

func waitActualMuseResult(path, expected string, exact bool, deadline time.Duration) (string, error) {
	until := time.Now().Add(deadline)
	var last error
	for time.Now().Before(until) {
		sessionID, err := acceptActualMuseResult(path, expected, exact)
		if err == nil {
			return sessionID, nil
		}
		last = err
		time.Sleep(100 * time.Millisecond)
	}
	return "", fmt.Errorf("real Muse did not produce an accepted terminal result: %w", last)
}

func waitActualMuseExit(path string, deadline time.Duration) error {
	until := time.Now().Add(deadline)
	var last error
	for time.Now().Before(until) {
		if err := acceptActualMuseExit(path); err == nil {
			return nil
		} else {
			last = err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("real Muse did not record a clean exit: %w", last)
}

func hasActualMuseResume(arguments []string, expected string) bool {
	for index, argument := range arguments {
		if argument == "resume" && index+1 < len(arguments) && arguments[index+1] == expected {
			return true
		}
	}
	return false
}

func hasActualMuseSession(arguments []string, expected string) bool {
	for index, argument := range arguments {
		if argument == "--session-id" && index+1 < len(arguments) && arguments[index+1] == expected {
			return true
		}
	}
	return false
}

func proveActualMuseToolFreeRecall(state, attemptID, bindingID, sessionID string) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		counts, err := recoveryHookCounts(state, attemptID, bindingID, sessionID)
		if err != nil {
			return err
		}
		if counts["PreToolUse"] > 0 || counts["PostToolUse"] > 0 || counts["PostToolUseFailure"] > 0 {
			return errors.New("real Muse recall used a tool")
		}
		if counts["Stop"] > 0 {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("real Muse recall Stop observation was not committed")
}

type actualMuseToolPair struct {
	Pre  int
	Post int
}

func actualMuseCompletedTools(state, attemptID, bindingID string) (map[string]actualMuseToolPair, error) {
	db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query("SELECT record_json FROM bee_thread_records WHERE kind='observation' AND source='bee' ORDER BY sequence")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	tools := map[string]actualMuseToolPair{}
	for rows.Next() {
		var encoded string
		if err := rows.Scan(&encoded); err != nil {
			return nil, err
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
		fields, _ := payload["fields"].(map[string]any)
		name, _ := fields["tool_name"].(string)
		if name == "" {
			continue
		}
		pair := tools[name]
		switch payload["event"] {
		case "PreToolUse":
			pair.Pre++
		case "PostToolUse":
			pair.Post++
		}
		tools[name] = pair
	}
	return tools, rows.Err()
}

func museToolNames(tools map[string]actualMuseToolPair) []string {
	names := make([]string, 0, len(tools))
	for name := range tools {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func completedMuseTool(tools map[string]actualMuseToolPair, match func(string) bool) bool {
	for name, pair := range tools {
		if match(name) && pair.Pre > 0 && pair.Pre == pair.Post {
			return true
		}
	}
	return false
}

func museThreadReadTool(name string) bool {
	lower := strings.ToLower(name)
	return strings.Contains(lower, "bee") && strings.Contains(lower, "thread_read")
}

func museFixtureReadTool(name string) bool {
	lower := strings.ToLower(name)
	if museThreadReadTool(name) {
		return false
	}
	return strings.Contains(lower, "read") || strings.Contains(lower, "file") ||
		strings.Contains(lower, "shell") || strings.Contains(lower, "command") || strings.Contains(lower, "terminal")
}

func TestActualMuseManagedColdRecovery(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("MUSE_BIN")
	loginFile := os.Getenv("MUSE_LOGIN_FILE")
	if binary == "" || executable == "" || loginFile == "" {
		t.Fatal("BEE_BINARY, MUSE_BIN and MUSE_LOGIN_FILE are required")
	}
	if err := actualMuseColdRecovery(binary, executable, loginFile); err != nil {
		t.Fatal(err)
	}
	t.Log("real Muse recalled an exact token with stable conversation/HOME/application/thread, a fresh attempt and gateway, and no prompt replay")
}

func actualMuseColdRecovery(binary, executable, loginFile string) (result error) {
	root, err := os.MkdirTemp("", "bee-real-muse-recovery-")
	if err != nil {
		return err
	}
	defer func() {
		cleanupErr := os.RemoveAll(root)
		if cleanupErr == nil {
			if _, statErr := os.Stat(root); statErr != nil && !os.IsNotExist(statErr) {
				cleanupErr = statErr
			} else if statErr == nil {
				cleanupErr = errors.New("temporary Muse root still exists after cleanup")
			}
		}
		if result == nil && cleanupErr != nil {
			result = fmt.Errorf("remove credential-bearing Muse acceptance state: %w", cleanupErr)
		}
	}()
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	for _, dir := range []string{filepath.Join(project, "bin"), state, filepath.Join(home, ".config", "muse")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
	}
	loginBefore, err := os.ReadFile(loginFile)
	if err != nil || len(loginBefore) == 0 {
		return errors.New("real Muse login unavailable")
	}
	if len(loginBefore) > 8192 {
		return errors.New("real Muse login is too large")
	}
	if err := os.WriteFile(filepath.Join(home, ".config", "muse", "auth.json"), loginBefore, 0600); err != nil {
		return err
	}
	globalSettingsPath := filepath.Join(home, ".config", "muse", "settings.json")
	if err := os.WriteFile(globalSettingsPath, []byte(museGlobalSettings), 0600); err != nil {
		return err
	}
	globalSettingsBefore, err := os.ReadFile(globalSettingsPath)
	if err != nil {
		return err
	}

	firstReport, secondReport := filepath.Join(root, "first-launch"), filepath.Join(root, "second-launch")
	firstResult, secondResult := filepath.Join(root, "first-result.jsonl"), filepath.Join(root, "second-result.jsonl")
	firstTask, secondTask := filepath.Join(root, "first-task"), filepath.Join(root, "second-task")
	token := fmt.Sprintf("BEE_MUSE_COLD_%d", time.Now().UnixNano())
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	// Muse 1.3.0 validates --session-id as a UUID. The wrapper owns this
	// first-session identity; Bee supplies the resume reference only on the
	// second public-window launch.
	sessionID := fmt.Sprintf("00000000-0000-4000-8000-%012x", uint64(time.Now().UnixNano())&0xffffffffffff)
	if err := os.WriteFile(filepath.Join(root, "session-id"), []byte(sessionID+"\n"), 0600); err != nil {
		return err
	}
	firstPrompt := "First call the scoped Bee thread_read MCP tool once. Then read fixture.txt with the file reading tool without changing any file. Remember its content for a later question. Reply with exactly its content. Do not run commands or write files."
	secondPrompt := "What exact token did I ask you to remember earlier? Reply with only that token and do not use tools."
	if err := os.WriteFile(firstTask, []byte(firstPrompt), 0600); err != nil {
		return err
	}
	if err := os.WriteFile(secondTask, []byte(secondPrompt), 0600); err != nil {
		return err
	}
	script := "#!/bin/sh\nset -eu\numask 077\nif [ \"${XDG_CONFIG_HOME+x}\" = x ]; then exit 2; fi\nphase=first\nif [ -f \"$HOME/bee-session-proof\" ]; then phase=second; fi\n" +
		"report=" + shellQuote(firstReport) + "\nresult=" + shellQuote(firstResult) + "\ntask=" + shellQuote(firstTask) + "\n" +
		"if [ \"$phase\" = second ]; then report=" + shellQuote(secondReport) + "; result=" + shellQuote(secondResult) + "; task=" + shellQuote(secondTask) + "; fi\n" +
		"session_id=$(sed -n '1p' " + shellQuote(filepath.Join(root, "session-id")) + ")\nresume=\nprevious=\nfor argument in \"$@\"; do if [ \"$previous\" = resume ]; then resume=$argument; fi; previous=$argument; done\n" +
		"if [ \"$phase\" = first ] && [ -n \"$resume\" ]; then exit 2; fi\nif [ \"$phase\" = second ] && [ \"$resume\" != \"$session_id\" ]; then exit 2; fi\n" +
		"printf '%s\\n%s\\nxdg-config-home-unset\\n' \"$PWD\" \"$HOME\" > \"$report\"\nprintf 'bee-args\\n' >> \"$report\"\nprintf '%s\\n' \"$@\" >> \"$report\"\n" +
		"set -- exec --json --approval-mode never --reasoning-effort high --max-model-steps 8 --workspace \"$PWD\" --session-id \"$session_id\" -- \"$(sed -n '1p' \"$task\")\"\nprintf 'exec-args\\n' >> \"$report\"\nprintf '%s\\n' \"$@\" >> \"$report\"\n" +
		"for retained_file in \"$HOME/.config/muse/auth.json\" \"$HOME/.config/muse/settings.json\" \"$HOME/.config/muse/.bee-global-settings.json\"; do [ -f \"$retained_file\" ] || exit 2; done\n" +
		// Muse's experimental reminder agents are unrelated provider turns.
		// Disable them in this exact-session acceptance so the gate proves the
		// requested conversation rather than spending extra model turns on
		// provider-owned skill, goal or verification reminders.
		"set +e\nMUSE_EXPERIMENTAL_SKILL_REMINDER=0 MUSE_EXPERIMENTAL_GOAL_REMINDER=0 MUSE_EXPERIMENTAL_VERIFY_REMINDER=0 " + shellQuote(executable) + " \"$@\" > \"$result\" 2> \"$result.stderr\"\nstatus=$?\nset -e\nprintf '%s\\n' \"$status\" > \"$result.status\"\nprintf retained > \"$HOME/bee-session-proof\"\nprintf 'BEE_RECOVERY_AGENT_READY_%s\\n' \"$phase\"\nIFS= read -r answer\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "muse"), []byte(script), 0700); err != nil {
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
			result = fmt.Errorf("clean real Muse acceptance processes: %w", cleanupErr)
		}
	}()

	first, err = newDesktop(binary, project, state, home)
	if err != nil {
		return err
	}
	if err = first.waitFor("Choose a profile", 25*time.Second); err != nil {
		return err
	}
	if err = first.waitFor("Muse", 25*time.Second); err != nil {
		return err
	}
	if err = first.send("\x1b[B\x1b[B\x1b[B\x1b[B\r"); err != nil {
		return err
	}
	for _, detail := range []string{"Configured folder", "No instructions", "14 tools configured"} {
		if err = first.waitFor(detail, 5*time.Second); err != nil {
			return fmt.Errorf("real Muse profile summary: %w", err)
		}
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	if err = first.waitFor("BEE_RECOVERY_AGENT_READY_first", 120*time.Second); err != nil {
		return err
	}
	resultSessionID, err := acceptActualMuseResult(firstResult, token, true)
	if err != nil {
		return err
	}
	if err := acceptActualMuseExit(firstResult); err != nil {
		return err
	}
	if resultSessionID != sessionID {
		return errors.New("real Muse result changed the requested conversation identity")
	}
	if err := os.Remove(filepath.Join(project, "fixture.txt")); err != nil {
		return err
	}
	firstLaunch, err := readActualMuseLaunch(firstReport)
	if err != nil {
		return err
	}
	if firstLaunch.Directory != project || firstLaunch.Home == "" || !firstLaunch.XDGUnset {
		return errors.New("first real Muse launch changed its project or omitted its retained home/unset XDG_CONFIG_HOME")
	}
	if err := assertMuseSettings(firstLaunch.Home, globalSettingsBefore, loginBefore); err != nil {
		return err
	}
	sourceAfter, err := os.ReadFile(globalSettingsPath)
	if err != nil || !bytes.Equal(sourceAfter, globalSettingsBefore) {
		return errors.New("real Muse recovery changed the source global settings")
	}
	if hasActualMuseResume(firstLaunch.BeeArguments, sessionID) || strings.Contains(strings.Join(firstLaunch.BeeArguments, "\n"), firstPrompt) {
		return errors.New("first real Muse launch carried recovery state or the wrapper task")
	}
	if !hasActualMuseSession(firstLaunch.ExecArguments, sessionID) || strings.Contains(strings.Join(firstLaunch.ExecArguments, "\n"), "resume") {
		return errors.New("first real Muse exec did not use its explicit session id")
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
	if err := assertManagedRoute(state, "muse"); err != nil {
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
		return errors.New("real Muse checkpoint attempt is absent")
	}
	oldBinding, err := readRecoveryBinding(state, old.AttemptID)
	if err != nil {
		return err
	}
	oldHookFile, oldHookPath, err := assertMuseHookTokenSource(firstLaunch.Home, old.AttemptID)
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
			return fmt.Errorf("real Muse first turn omitted %s hook", event)
		}
	}
	var tools map[string]actualMuseToolPair
	toolDeadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(toolDeadline) {
		tools, err = actualMuseCompletedTools(state, old.AttemptID, oldBinding)
		if err != nil {
			return err
		}
		if completedMuseTool(tools, museThreadReadTool) && completedMuseTool(tools, museFixtureReadTool) {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !completedMuseTool(tools, museThreadReadTool) {
		return fmt.Errorf("real Muse first turn did not complete scoped Bee thread_read; observed tool names=%v", museToolNames(tools))
	}
	if !completedMuseTool(tools, museFixtureReadTool) {
		return fmt.Errorf("real Muse first turn did not complete a file-reading tool; observed tool names=%v", museToolNames(tools))
	}
	turns, successes, err := recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Muse first turn invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
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
	// The public window title is the UI proof that recovery launched and
	// attached. Provider completion is proved independently from its JSONL;
	// a wrapper marker printed during terminal handoff is not a stable frame.
	if err = second.waitFor("Muse CLI · Working", 30*time.Second); err != nil {
		return err
	}
	secondSessionID, err := waitActualMuseResult(secondResult, token, true, 120*time.Second)
	if err != nil {
		return err
	}
	if err := waitActualMuseExit(secondResult, 15*time.Second); err != nil {
		return err
	}
	if secondSessionID != sessionID {
		return errors.New("real Muse recovery changed its conversation identity")
	}
	secondLaunch, err := readActualMuseLaunch(secondReport)
	if err != nil {
		return err
	}
	if secondLaunch.Directory != firstLaunch.Directory || secondLaunch.Home != firstLaunch.Home || !secondLaunch.XDGUnset || !hasActualMuseResume(secondLaunch.BeeArguments, sessionID) {
		return errors.New("real Muse recovery changed its project/HOME, inherited XDG_CONFIG_HOME, or omitted its conversation reference")
	}
	if err := assertMuseSettings(secondLaunch.Home, globalSettingsBefore, loginBefore); err != nil {
		return err
	}
	if strings.Contains(strings.Join(secondLaunch.BeeArguments, "\n"), firstPrompt) || strings.Contains(strings.Join(secondLaunch.ExecArguments, "\n"), firstPrompt) {
		return errors.New("real Muse recovery replayed the original task prompt")
	}
	if !hasActualMuseSession(secondLaunch.ExecArguments, sessionID) {
		return errors.New("real Muse recovery exec omitted its explicit session id")
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
		return errors.New("real Muse recovery changed application or thread identity")
	}
	if err := assertManagedRoute(state, "muse"); err != nil {
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
		return errors.New("real Muse predecessor did not retire cleanly")
	}
	if fresh.AttemptID == "" || fresh.AttemptID == old.AttemptID || fresh.ActionID != old.ActionID || !recoveryIdentityValid(fresh) {
		return errors.New("real Muse recovery did not create one fresh measured attempt")
	}
	newBinding, err := readRecoveryBinding(state, fresh.AttemptID)
	if err != nil {
		return err
	}
	if newBinding == oldBinding {
		return errors.New("real Muse recovery reused its gateway binding")
	}
	newHookFile, newHookPath, err := assertMuseHookTokenSource(secondLaunch.Home, fresh.AttemptID)
	if err != nil {
		return err
	}
	if newHookPath == oldHookPath || bytes.Equal(newHookFile, oldHookFile) {
		return errors.New("real Muse recovery reused its hook credential file or token")
	}
	oldHookAfter, err := os.ReadFile(oldHookPath)
	if err != nil || !bytes.Equal(oldHookAfter, oldHookFile) {
		return errors.New("real Muse recovery rewrote its predecessor hook credential file")
	}
	if err := proveActualMuseToolFreeRecall(state, fresh.AttemptID, newBinding, sessionID); err != nil {
		return err
	}
	turns, successes, err = recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil || turns != 0 || successes != 0 {
		return fmt.Errorf("real Muse recovery invented Bee turn facts: turns=%d successes=%d err=%v", turns, successes, err)
	}
	loginAfter, err := os.ReadFile(loginFile)
	if err != nil || string(loginAfter) != string(loginBefore) {
		return errors.New("real Muse recovery changed the source login")
	}
	if _, err := os.Stat(filepath.Join(project, ".config")); !os.IsNotExist(err) {
		return errors.New("real Muse recovery wrote provider configuration into the project")
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
	if err := assertMuseSettings(secondLaunch.Home, globalSettingsBefore, loginBefore); err != nil {
		return err
	}
	sourceAfter, err = os.ReadFile(globalSettingsPath)
	if err != nil || !bytes.Equal(sourceAfter, globalSettingsBefore) {
		return errors.New("real Muse recovery changed the source global settings")
	}
	alive, err := recoveryIdentityAlive(fresh)
	if err != nil {
		return err
	}
	if alive {
		return errors.New("real Muse process remained alive after final owner stop")
	}
	if err := os.WriteFile(filepath.Join(project, "fixture.txt"), []byte(token+"\n"), 0600); err != nil {
		return err
	}
	projectAfter, err := treeFingerprint(project)
	if err != nil {
		return err
	}
	if projectAfter != projectBefore {
		return errors.New("real Muse recovery changed the project tree")
	}
	return nil
}
