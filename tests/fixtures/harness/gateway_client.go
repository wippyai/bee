// MIT. Standard-library HTTP clients used by the Claude fixture executable.
// This is test-fixture code and is compiled into bin/gateway-client before the
// fixture directory is copied into an isolated test workspace.
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type object = map[string]any

type rpcReply struct {
	status int
	body   object
}

type httpClient struct {
	client *http.Client
}

func newHTTPClient(timeout time.Duration) *httpClient {
	return &httpClient{client: &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{DisableKeepAlives: true},
	}}
}

func (c *httpClient) post(url string, authorization string, payload object) rpcReply {
	body, err := json.Marshal(payload)
	if err != nil {
		return rpcReply{}
	}
	request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return rpcReply{}
	}
	request.Header.Set("Authorization", authorization)
	request.Header.Set("Content-Type", "application/json")
	response, err := c.client.Do(request)
	if err != nil {
		return rpcReply{}
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return rpcReply{status: response.StatusCode}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return rpcReply{status: response.StatusCode}
	}
	var decoded object
	if err := json.Unmarshal(responseBody, &decoded); err != nil {
		return rpcReply{status: response.StatusCode}
	}
	return rpcReply{status: response.StatusCode, body: decoded}
}

func hookPost(c *httpClient, url string, token string, payload object) (int, string) {
	body, err := json.Marshal(payload)
	if err != nil {
		return 0, ""
	}
	request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 0, ""
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := c.client.Do(request)
	if err != nil {
		return 0, err.Error()
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(response.Body)
	if err != nil {
		return response.StatusCode, ""
	}
	return response.StatusCode, string(responseBody)
}

func mustObject(value any) object {
	decoded, ok := value.(object)
	if !ok {
		return nil
	}
	return decoded
}

func stringField(value any, name string) string {
	if item := mustObject(value); item != nil {
		if text, ok := item[name].(string); ok {
			return text
		}
	}
	return ""
}

func outcome(reply rpcReply) object {
	result := mustObject(reply.body["result"])
	content, ok := result["content"].([]any)
	if !ok || len(content) == 0 {
		return nil
	}
	text := stringField(content[0], "text")
	if text == "" {
		return nil
	}
	var decoded object
	if json.Unmarshal([]byte(text), &decoded) != nil {
		return nil
	}
	return decoded
}

func rpc(c *httpClient, url string, authorization string, method string, params object, ident int) rpcReply {
	return c.post(url, authorization, object{
		"jsonrpc": "2.0",
		"id":      ident,
		"method":  method,
		"params":  params,
	})
}

func jsonArg(value string) (any, bool) {
	var decoded any
	if json.Unmarshal([]byte(value), &decoded) != nil {
		return nil, false
	}
	return decoded, true
}

func runHooks(settingsLiteral string) int {
	settingsValue, ok := jsonArg(settingsLiteral)
	if !ok {
		return 0
	}
	settings := mustObject(settingsValue)
	urls, ok := settings["allowedHttpHookUrls"].([]any)
	if !ok || len(urls) == 0 {
		return 0
	}
	url, ok := urls[0].(string)
	if !ok || url == "" {
		return 0
	}
	token := os.Getenv("BEE_GATEWAY_HOOK_TOKEN")
	c := newHTTPClient(10 * time.Second)
	session := "fixture-session"
	workingDirectory, _ := os.Getwd()
	events := []object{
		{"hook_event_name": "SessionStart", "session_id": session, "source": "startup", "cwd": workingDirectory},
		{"hook_event_name": "UserPromptSubmit", "session_id": session, "prompt_id": "prompt-1", "prompt": "the brief"},
		{"hook_event_name": "PreToolUse", "session_id": session, "prompt_id": "prompt-1", "tool_use_id": "toolu_fixture_1", "tool_name": "Bash", "tool_input": object{"command": "true", "secret": "sk-fixture-000"}},
		{"hook_event_name": "PostToolUse", "session_id": session, "prompt_id": "prompt-1", "tool_use_id": "toolu_fixture_1", "tool_name": "Bash", "tool_response": object{"stdout": "", "stderr": ""}, "duration_ms": 5, "decision": "block"},
		{"hook_event_name": "Stop", "session_id": session, "prompt_id": "prompt-1", "stop_hook_active": false, "last_assistant_message": "done"},
	}
	statuses := make([]int, 0, len(events))
	for _, event := range events {
		status, _ := hookPost(c, url, token, event)
		statuses = append(statuses, status)
	}
	replayStatus, replayBody := hookPost(c, url, token, events[0])
	report := object{"statuses": statuses, "bodies_empty": replayBody == "", "replay": replayStatus}
	if flood, err := strconv.Atoi(os.Getenv("BEE_FIXTURE_HOOKS_FLOOD")); err == nil && flood > 0 {
		codes := object{}
		for index := 0; index < flood; index++ {
			status, _ := hookPost(c, url, token, object{
				"hook_event_name": "PostToolUse",
				"session_id":      session,
				"prompt_id":       "prompt-1",
				"tool_use_id":     fmt.Sprintf("toolu_flood_%d", index),
				"tool_name":       "Bash",
			})
			key := strconv.Itoa(status)
			count, _ := codes[key].(int)
			codes[key] = count + 1
		}
		report["flood"] = codes
	}
	writeReport("hooks", report)
	return 0
}

func mcpConfig(literal string) (string, string, bool) {
	value, ok := jsonArg(literal)
	if !ok {
		return "", "", false
	}
	config := mustObject(value)
	servers := mustObject(config["mcpServers"])
	server := mustObject(servers["bee"])
	url, ok := server["url"].(string)
	if !ok || url == "" {
		return "", "", false
	}
	headers := mustObject(server["headers"])
	authorization, ok := headers["Authorization"].(string)
	if !ok {
		return "", "", false
	}
	authorization = strings.ReplaceAll(authorization, "${BEE_GATEWAY_TOKEN}", os.Getenv("BEE_GATEWAY_TOKEN"))
	return url, authorization, true
}

// codexConfig reads the bee server from a Codex config.toml the way Codex
// does: its url and the environment variable that holds the bearer token.
func codexConfig(path string) (string, string, bool) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", "", false
	}
	url, variable, section := "", "", ""
	for _, line := range strings.Split(string(content), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			section = line
			continue
		}
		if section != "[mcp_servers.bee]" {
			continue
		}
		name, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		unquoted, unquoteErr := strconv.Unquote(strings.TrimSpace(value))
		if unquoteErr != nil {
			continue
		}
		switch strings.TrimSpace(name) {
		case "url":
			url = unquoted
		case "bearer_token_env_var":
			variable = unquoted
		}
	}
	token := os.Getenv(variable)
	if url == "" || variable == "" || token == "" {
		return "", "", false
	}
	return url, "Bearer " + token, true
}

func runGateway(mcpLiteral string) int {
	url, authorization, ok := mcpConfig(mcpLiteral)
	if !ok {
		return 0
	}
	return runGatewayAt(url, authorization)
}

func runCodexGateway(configPath string) int {
	url, authorization, ok := codexConfig(configPath)
	if !ok {
		writeReport("gateway", object{"codex_config": "unreadable"})
		return 0
	}
	return runGatewayAt(url, authorization)
}

func runGatewayAt(url, authorization string) int {
	stopping := make(chan os.Signal, 1)
	signal.Notify(stopping, syscall.SIGTERM)
	defer signal.Stop(stopping)
	report := object{}
	// An MCP client waits for the gateway's reply: the gateway serves an
	// ordinary tool call to completion, and a delivery preflight on a loaded
	// machine can take longer than any fixed transport cutoff. Long-polling
	// waits carry their own budget through rpcWithTimeout.
	client := newHTTPClient(0)
	initialized := rpc(client, url, authorization, "initialize", object{
		"protocolVersion": "2025-06-18",
		"capabilities":    object{},
		"clientInfo":      object{"name": "bee-fixture", "version": "0"},
	}, 1)
	report["initialize"] = initialized.status
	if initialized.status == http.StatusOK {
		result := mustObject(initialized.body["result"])
		report["protocol"] = result["protocolVersion"]
	} else {
		report["protocol"] = nil
	}
	listed := rpc(client, url, authorization, "tools/list", object{}, 2)
	report["list"] = listed.status
	report["tools"] = []string{}
	if listed.status == http.StatusOK {
		result := mustObject(listed.body["result"])
		tools, ok := result["tools"].([]any)
		if ok {
			names := make([]string, 0, len(tools))
			for _, item := range tools {
				if name := stringField(item, "name"); name != "" {
					names = append(names, name)
				}
			}
			sort.Strings(names)
			report["tools"] = names
		}
	}
	readReply := rpc(client, url, authorization, "tools/call", object{
		"name":      "thread_read",
		"arguments": object{"cursor": 0},
	}, 3)
	report["read"] = readReply.status
	readValue := outcome(readReply)
	report["read_ok"] = readValue != nil && readValue["ok"] == true
	if definition := os.Getenv("BEE_FIXTURE_GATEWAY_LAUNCH"); definition != "" {
		reportLaunch(client, url, authorization, report, definition, os.Getenv("BEE_FIXTURE_GATEWAY_BRIEF"))
	}
	if definition := os.Getenv("BEE_FIXTURE_GATEWAY_RUN_CONTROL"); definition != "" {
		reportRunControl(client, url, authorization, report, definition, os.Getenv("BEE_FIXTURE_GATEWAY_RUN_BRIEF"))
	}
	if definition := os.Getenv("BEE_FIXTURE_GATEWAY_ORCHESTRATOR_RUN"); definition != "" {
		reportOrchestratorRun(client, url, authorization, report, definition, os.Getenv("BEE_FIXTURE_GATEWAY_RUN_BRIEF"))
	}
	if marker := os.Getenv("BEE_FIXTURE_GATEWAY_WORKER"); marker != "" {
		reportWorker(client, url, authorization, report, marker)
	}
	if mode := os.Getenv("BEE_FIXTURE_GATEWAY_AUTHOR"); mode == "spec" {
		reportSpecAuthoring(client, url, authorization, report)
	} else if mode != "" {
		reportAuthoring(client, url, authorization, report, mode)
	}
	if os.Getenv("BEE_FIXTURE_GATEWAY_APP_OPEN") != "" {
		reportApplicationOpen(client, url, authorization, report)
	}
	if os.Getenv("BEE_FIXTURE_GATEWAY_SURFACE") == "1" {
		reportSurface(client, url, authorization, report)
	}
	if role := os.Getenv("BEE_FIXTURE_PEER_ROLE"); role != "" {
		if strings.HasPrefix(role, "inbox_") {
			reportInboxPeer(url, authorization, report, role)
		} else {
			reportPeer(url, authorization, report, role)
		}
	}
	if waitMS, err := strconv.Atoi(os.Getenv("BEE_FIXTURE_GATEWAY_WAIT")); err == nil && waitMS > 0 {
		reportWait(client, url, authorization, report, readValue, waitMS)
	}
	// BEE_FIXTURE_GATEWAY_HOLD holds the child for that many seconds, or with
	// "stop" until it is stopped, then presents its token once more.
	holdSetting := os.Getenv("BEE_FIXTURE_GATEWAY_HOLD")
	if hold, err := strconv.ParseFloat(holdSetting, 64); (err == nil && hold > 0) || holdSetting == "stop" {
		var elapsed <-chan time.Time
		if err == nil {
			timer := time.NewTimer(time.Duration(hold * float64(time.Second)))
			defer timer.Stop()
			elapsed = timer.C
		}
		select {
		case <-elapsed:
		case <-stopping:
			report["after_hold"] = rpc(client, url, authorization, "tools/list", object{}, 5).status
			writeReport("gateway", report)
			return 143
		}
		report["after_hold"] = rpc(client, url, authorization, "tools/list", object{}, 5).status
	}
	writeReport("gateway", report)
	return 0
}

// The scripted application-opening agent uses only the MCP surface delivered
// by its managed carrier. The host owns admission and credential delivery; the
// child requests its declared trait, waits for the durable decision, selects
// it, opens twice with distinct retry keys, and leaves its evidence on the
// bound thread before exiting.
func reportApplicationOpen(client *httpClient, url, authorization string, report object) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	target := os.Getenv("BEE_FIXTURE_APP_DEFINITION")
	if target == "" {
		report["app_open_error"] = "target definition is missing"
		return
	}
	// application_open belongs to the requested trait and must not be usable
	// before the owner grants and the child selects that trait.
	before := call("application_open", object{"definition_id": target, "arguments": []string{}, "idempotency_key": "unapproved-open"}, 60)
	report["unapproved_refused"] = before == nil || before["ok"] != true
	session := call("session", object{"operation": "read"}, 61)
	report["session_read"] = session != nil && session["ok"] == true
	requested := call("session", object{"operation": "request_access", "idempotency_key": "app-open-runtime",
		"traits": []string{"bee.application:runtime"}, "reason": "Open the reviewed application and report its bound thread progress"}, 62)
	report["app_open_request"] = requested
	if requested == nil || requested["ok"] != true {
		report["app_open_error"] = "access request failed"
		return
	}
	requestValue := mustObject(requested["value"])
	approvalID := stringField(requestValue, "approval_id")
	report["approval_id"] = approvalID
	var granted object
	for attempt := 0; attempt < 300 && approvalID != ""; attempt++ {
		status := call("session", object{"operation": "access_status", "approval_id": approvalID}, 63+attempt)
		value := mustObject(status["value"])
		if stringField(value, "status") == "granted" {
			granted = value
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if granted == nil {
		report["app_open_error"] = "access was not granted"
		return
	}
	revision, ok := granted["revision"].(float64)
	if !ok || revision < 1 {
		report["app_open_error"] = "grant revision is missing"
		return
	}
	selected := call("session", object{"operation": "select", "expected_revision": int(revision),
		"active_traits": []string{"bee.application:runtime"}, "context": object{}}, 400)
	report["selected"] = selected != nil && selected["ok"] == true
	first := call("application_open", object{"definition_id": target, "arguments": []string{}, "idempotency_key": "open-first"}, 401)
	second := call("application_open", object{"definition_id": target, "arguments": []string{}, "idempotency_key": "open-second"}, 402)
	report["app_open_first"], report["app_open_second"] = first, second
	if first == nil || second == nil || first["ok"] != true || second["ok"] != true {
		report["app_open_error"] = "application open failed"
		return
	}
	firstValue, secondValue := mustObject(first["value"]), mustObject(second["value"])
	if firstValue == nil || secondValue == nil {
		report["app_open_error"] = "application open returned no identity"
		return
	}
	var windowValue object
	if window := os.Getenv("BEE_FIXTURE_WINDOW_DEFINITION"); window != "" {
		opened := call("application_open", object{"definition_id": window, "arguments": []string{}, "idempotency_key": "open-window"}, 403)
		if opened == nil || opened["ok"] != true {
			report["app_open_error"] = "managed window open failed"
			return
		}
		windowValue = mustObject(opened["value"])
		if windowValue == nil {
			report["app_open_error"] = "managed window returned no identity"
			return
		}
	}
	proof := object{"schema": "managed-app-open.v1", "approval_id": approvalID,
		"unapproved_refused": report["unapproved_refused"], "selected": report["selected"],
		"first_instance": firstValue["instance_id"], "second_instance": secondValue["instance_id"],
		"first_view": firstValue["view_id"], "second_view": secondValue["view_id"],
		"first_display": firstValue["display_id"], "second_display": secondValue["display_id"]}
	if windowValue != nil {
		proof["window_definition"] = windowValue["definition_id"]
		proof["window_instance"] = windowValue["instance_id"]
		proof["window_view"] = windowValue["view_id"]
		proof["window_display"] = windowValue["display_id"]
	}
	encoded, err := json.Marshal(proof)
	if err != nil {
		report["app_open_error"] = err.Error()
		return
	}
	posted := call("thread_message", object{"idempotency_key": "managed-app-open-proof", "message_id": "managed-app-open-proof",
		"message_kind": "progress", "recipient_ids": []string{}, "content": object{"text": string(encoded)}}, 404)
	report["app_open_posted"] = posted != nil && posted["ok"] == true
}

// The scripted orchestrator agent. It starts exactly one allow-listed child
// through thread_launch and returns as soon as the child's answer moves the
// thread; the records and the lineage are asserted from the thread itself.
func reportLaunch(client *httpClient, url, authorization string, report object, definition, brief string) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	// The orchestrator's own launch reports whether the managed-run tools and
	// the discovery tools its host policy admits are actually offered.
	names, _ := toolsOf(rpc(client, url, authorization, "tools/list", object{}, 29))
	report["orchestrator_tools"] = names
	launchArgs := object{"definition_ref": definition, "brief": brief, "idempotency_key": "k"}
	if title := os.Getenv("BEE_FIXTURE_ORCHESTRATOR_THREAD_TITLE"); title != "" {
		launchArgs["thread"] = object{"title": title}
	}
	launched := call("thread_launch", launchArgs, 30)
	report["launch_ok"] = launched != nil && launched["ok"] == true
	value := mustObject(launched["value"])
	if value == nil {
		report["launch_refusal"] = launched
		return
	}
	report["child_thread"] = value["thread_id"]
	report["child_action"] = value["action_id"]
	report["child_attempt"] = value["attempt_id"]
	report["child_definition"] = value["definition_ref"]
	report["child_title"] = value["title"]
	report["child_brief"] = value["brief"]
	// Read the thread first so the wait starts from the current head, then wait
	// for the child to answer and settle.
	readBack := call("thread_read", object{"cursor": 0, "limit": 64}, 31)
	readValue := mustObject(readBack["value"])
	head := 0
	if readValue != nil {
		if scanned, ok := readValue["scanned_through"].(float64); ok {
			head = int(scanned)
		}
	}
	// Wait until the child's answer is on the thread, then until the child's
	// own terminal receipt is, so the parent really observes that attempt's
	// outcome and not just any movement or another action's receipt. Every
	// wait is bounded by the transport budget the tool sets.
	childAction := stringField(value, "action_id")
	marker := os.Getenv("BEE_FIXTURE_WORKER_MARKER")
	answered := false
	settled := false
	waits := 0
	for attempt := 0; attempt < 12 && !(answered && settled); attempt++ {
		waits++
		waited := rpcWithTimeout(client, url, authorization, "tools/call", object{
			"name":      "thread_wait",
			"arguments": object{"after_sequence": head, "wait_ms": 20000},
		}, 32+attempt, 40*time.Second)
		outcomeValue := outcome(waited)
		waitReport := mustObject(outcomeValue["value"])
		if scanned, ok := waitReport["scanned_through"].(float64); ok {
			head = int(scanned)
		}
		final := call("thread_read", object{"cursor": head, "limit": 64}, 44+attempt)
		finalValue := mustObject(final["value"])
		records := []any{}
		if finalValue != nil {
			if list, ok := finalValue["records"].([]any); ok {
				records = list
			}
		}
		for _, raw := range records {
			record := mustObject(raw)
			if kind := stringField(record, "kind"); kind == "receipt" && stringField(record, "action_id") == childAction {
				settled = true
			}
			body := mustObject(record["body"])
			content := mustObject(body["content"])
			if text := stringField(content, "text"); text != "" && strings.Contains(text, marker) {
				answered = true
			}
		}
		if scanned, ok := finalValue["scanned_through"].(float64); ok {
			head = int(scanned)
		}
	}
	report["waits"] = waits
	report["final_marker"] = answered
	report["final_receipt"] = settled
	// Read the run back through the managed-run tool, naming the child's thread
	// and attempt the launch returned. This is the same identity an orchestrator
	// uses after a child runs on a thread of its own.
	if status := call("run_status", object{"thread_id": stringField(value, "thread_id"), "attempt_id": stringField(value, "attempt_id")}, 90); status != nil {
		report["run_status_ok"] = status["ok"] == true
		statusValue := mustObject(status["value"])
		if statusValue != nil {
			report["run_state"] = statusValue["state"]
			report["run_outcome"] = statusValue["outcome"]
		}
	}
}

// The orchestrator's managed-run controls over a second child it launches and
// then cancels: run_status reads its state, run_cancel stops it and reports a
// terminal state. The cancel intent is durable and idempotent.
func reportRunControl(client *httpClient, url, authorization string, report object, definition, brief string) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	launchArgs := object{"definition_ref": definition, "brief": brief, "idempotency_key": "cancel-k"}
	if title := os.Getenv("BEE_FIXTURE_ORCHESTRATOR_CANCEL_TITLE"); title != "" {
		launchArgs["thread"] = object{"title": title}
	}
	launched := call("thread_launch", launchArgs, 92)
	report["cancel_launch_ok"] = launched != nil && launched["ok"] == true
	value := mustObject(launched["value"])
	if value == nil {
		report["cancel_launch_refusal"] = launched
		return
	}
	threadID, attemptID := stringField(value, "thread_id"), stringField(value, "attempt_id")
	initial := call("run_status", object{"thread_id": threadID, "attempt_id": attemptID}, 93)
	report["cancel_status_ok"] = initial != nil && initial["ok"] == true
	cancelled := call("run_cancel", object{"thread_id": threadID, "attempt_id": attemptID, "idempotency_key": "cancel-once", "wait_ms": 20000}, 94)
	report["cancel_ok"] = cancelled != nil && cancelled["ok"] == true
	cancelValue := mustObject(cancelled["value"])
	if cancelValue != nil {
		report["cancel_state"] = cancelValue["state"]
		report["cancel_outcome"] = cancelValue["outcome"]
	}
	replayed := call("run_cancel", object{"thread_id": threadID, "attempt_id": attemptID, "idempotency_key": "cancel-once", "wait_ms": 20000}, 95)
	report["cancel_replay_ok"] = replayed != nil && replayed["ok"] == true
	// A run identity the orchestrator never launched must not be readable
	// through the managed-run tool.
	foreign := call("run_status", object{"thread_id": "not-a-launched-thread", "attempt_id": "not-a-launched-attempt"}, 96)
	report["cancel_foreign_refused"] = foreign == nil || foreign["ok"] != true
}

// The scripted orchestrator for the managed-run proof. It launches a Codex
// worker on a thread of its own, is told by thread_notify when that child ends
// and wakes on thread_wait, reads the child's thread by naming it member_thread,
// queries the run with run_status, steers the child once by writing to its
// thread, then launches a second worker on a new thread and cancels it with
// run_cancel. Every step uses only the tools the orchestrator's own launch
// policy admits. It reports statuses only; the records are asserted from the
// threads themselves.
func reportOrchestratorRun(client *httpClient, url, authorization string, report object, definition, brief string) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	names, _ := toolsOf(rpc(client, url, authorization, "tools/list", object{}, 28))
	report["orchestrator_tools"] = names
	// The capabilities report advertises launch_definitions whenever the launch
	// tool is admitted; calling discovery must therefore be admitted too, over
	// the same host-selected launch policy.
	if containsName(names, "launch_definitions") {
		definitions := call("launch_definitions", object{}, 29)
		report["definitions_call_ok"] = definitions != nil && definitions["ok"] == true
		definitionsValue := mustObject(definitions["value"])
		if definitionsValue != nil {
			if list, ok := definitionsValue["definitions"].([]any); ok {
				report["definitions_count"] = len(list)
			}
		}
	}
	marker := os.Getenv("BEE_FIXTURE_WORKER_MARKER")
	// Worker one: a new thread, a completion observed through notify and wait.
	first := call("thread_launch", object{"definition_ref": definition, "brief": brief, "idempotency_key": "run-first",
		"thread": object{"title": os.Getenv("BEE_FIXTURE_ORCHESTRATOR_THREAD_TITLE")}}, 30)
	report["first_launch_ok"] = first != nil && first["ok"] == true
	firstValue := mustObject(first["value"])
	if firstValue == nil {
		report["first_launch_refusal"] = first
		return
	}
	childThread, childAction, childAttempt := stringField(firstValue, "thread_id"), stringField(firstValue, "action_id"), stringField(firstValue, "attempt_id")
	report["first_thread"] = childThread
	// The launch reply names an admitted attempt before the child's gateway
	// binding opens, so register the durable notice immediately.
	notifyReply := rpcWithTimeout(client, url, authorization, "tools/call", object{"name": "thread_notify", "arguments": object{"thread_id": childThread, "attempt_id": childAttempt, "idempotency_key": "run-first-notify"}}, 31, 20*time.Second)
	notified := outcome(notifyReply)
	report["first_notify_ok"] = notified != nil && notified["ok"] == true
	report["first_notify_status"] = notifyReply.status
	// Read the child's own thread by name (member_thread), then wait on it for
	// the child's answer and terminal receipt.
	readBack := call("thread_read", object{"cursor": 0, "limit": 64, "member_thread": childThread}, 32)
	readValue := mustObject(readBack["value"])
	head := 0
	if readValue != nil {
		if scanned, ok := readValue["scanned_through"].(float64); ok {
			head = int(scanned)
		}
	}
	answered, settled, notifyFired := false, false, false
	for attempt := 0; attempt < 12 && !(answered && settled); attempt++ {
		waited := rpcWithTimeout(client, url, authorization, "tools/call", object{
			"name":      "thread_wait",
			"arguments": object{"after_sequence": head, "wait_ms": 20000, "member_thread": childThread},
		}, 33+attempt, 40*time.Second)
		outcomeValue := outcome(waited)
		waitReport := mustObject(outcomeValue["value"])
		if scanned, ok := waitReport["scanned_through"].(float64); ok {
			head = int(scanned)
		}
		final := call("thread_read", object{"cursor": head, "limit": 64, "member_thread": childThread}, 45+attempt)
		finalValue := mustObject(final["value"])
		records := []any{}
		if finalValue != nil {
			if list, ok := finalValue["records"].([]any); ok {
				records = list
			}
		}
		for _, raw := range records {
			record := mustObject(raw)
			kind := stringField(record, "kind")
			if kind == "receipt" && stringField(record, "action_id") == childAction {
				settled = true
			}
			if kind == "message" {
				content := mustObject(mustObject(record["body"])["content"])
				if text := stringField(content, "text"); text != "" && strings.Contains(text, marker) {
					answered = true
				}
			}
		}
		if scanned, ok := finalValue["scanned_through"].(float64); ok {
			head = int(scanned)
		}
	}
	report["first_answered"] = answered
	report["first_settled"] = settled
	// The one-shot notice lands on the orchestrator's own bound thread. The
	// owner settles it on the watched thread's next commit or its own periodic
	// sweep, so follow the bound thread forward on delivery wakeups until the
	// notice is durable or the wall-clock bound ends.
	ownCursor := 0
	deadline := time.Now().Add(90 * time.Second)
	for waited := 0; !notifyFired && time.Now().Before(deadline); waited++ {
		own := call("thread_read", object{"cursor": ownCursor, "limit": 64}, 58)
		ownValue := mustObject(own["value"])
		if ownValue != nil {
			if list, ok := ownValue["records"].([]any); ok {
				for _, raw := range list {
					record := mustObject(raw)
					if kind := stringField(record, "kind"); kind == "message" {
						body := mustObject(record["body"])
						if strings.HasPrefix(stringField(body, "message_id"), "notice:") {
							notifyFired = true
						}
					}
				}
			}
			if scanned, ok := ownValue["scanned_through"].(float64); ok {
				ownCursor = int(scanned)
			}
		}
		if !notifyFired && time.Now().Before(deadline) {
			rpcWithTimeout(client, url, authorization, "tools/call", object{
				"name":      "thread_wait",
				"arguments": object{"after_sequence": ownCursor, "wait_ms": 5000},
			}, 300+waited, 20*time.Second)
		}
	}
	report["notify_fired"] = notifyFired
	// Query the run by the child's identity the launch returned.
	status := call("run_status", object{"thread_id": childThread, "attempt_id": childAttempt}, 60)
	report["run_status_ok"] = status != nil && status["ok"] == true
	statusValue := mustObject(status["value"])
	if statusValue != nil {
		report["run_state"] = statusValue["state"]
		report["run_outcome"] = statusValue["outcome"]
	}
	// Steer the child exactly once by writing to its thread, then prove the
	// steer is durable there.
	steerText := "steer:" + marker
	steered := call("thread_message", object{"idempotency_key": "run-first-steer", "message_id": "run-first-steer",
		"message_kind": "progress", "recipient_ids": []string{}, "content": object{"text": steerText},
		"member_thread": childThread}, 61)
	report["steer_ok"] = steered != nil && steered["ok"] == true
	steerRead := call("thread_read", object{"cursor": 0, "limit": 64, "member_thread": childThread}, 62)
	steerValue := mustObject(steerRead["value"])
	steerSeen := false
	if steerValue != nil {
		if list, ok := steerValue["records"].([]any); ok {
			for _, raw := range list {
				record := mustObject(raw)
				if kind := stringField(record, "kind"); kind == "message" {
					content := mustObject(mustObject(record["body"])["content"])
					if stringField(content, "text") == steerText {
						steerSeen = true
					}
				}
			}
		}
	}
	report["steer_seen"] = steerSeen
	// A run identity the orchestrator never launched is not readable.
	foreign := call("run_status", object{"thread_id": "never-launched-thread", "attempt_id": "never-launched-attempt"}, 63)
	report["foreign_refused"] = foreign == nil || foreign["ok"] != true
	// Worker two: a second new thread, cancelled through run_cancel, and the
	// cancel replays instead of acting twice.
	second := call("thread_launch", object{"definition_ref": definition, "brief": brief, "idempotency_key": "run-second",
		"thread": object{"title": os.Getenv("BEE_FIXTURE_ORCHESTRATOR_CANCEL_TITLE")}}, 70)
	report["second_launch_ok"] = second != nil && second["ok"] == true
	secondValue := mustObject(second["value"])
	if secondValue == nil {
		report["second_launch_refusal"] = second
		return
	}
	secondThread, secondAttempt := stringField(secondValue, "thread_id"), stringField(secondValue, "attempt_id")
	report["second_thread"] = secondThread
	cancelled := call("run_cancel", object{"thread_id": secondThread, "attempt_id": secondAttempt,
		"idempotency_key": "run-second-cancel", "wait_ms": 20000}, 71)
	report["cancel_ok"] = cancelled != nil && cancelled["ok"] == true
	cancelValue := mustObject(cancelled["value"])
	if cancelValue != nil {
		report["cancel_state"] = cancelValue["state"]
		report["cancel_outcome"] = cancelValue["outcome"]
	}
	replayed := call("run_cancel", object{"thread_id": secondThread, "attempt_id": secondAttempt,
		"idempotency_key": "run-second-cancel", "wait_ms": 20000}, 72)
	report["cancel_replay_ok"] = replayed != nil && replayed["ok"] == true
	finalStatus := call("run_status", object{"thread_id": secondThread, "attempt_id": secondAttempt}, 73)
	report["second_status_ok"] = finalStatus != nil && finalStatus["ok"] == true
	finalValue := mustObject(finalStatus["value"])
	if finalValue != nil {
		report["second_final_state"] = finalValue["state"]
		report["second_final_outcome"] = finalValue["outcome"]
	}
}

// The scripted worker child. It reads the thread it was started on and posts
// its answer there, exactly as any managed agent hands a result back; the
// carrier settles the attempt when this fixture exits.
func reportWorker(client *httpClient, url, authorization string, report object, marker string) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	listed := rpc(client, url, authorization, "tools/list", object{}, 33)
	names, _ := toolsOf(listed)
	report["worker_tools"] = names
	readBack := call("thread_read", object{"cursor": 0, "limit": 64}, 34)
	value := mustObject(readBack["value"])
	report["worker_read_ok"] = value != nil
	posted := call("thread_message", object{"idempotency_key": "worker-answer-" + marker, "message_id": "worker-answer-" + marker,
		"message_kind": "progress", "recipient_ids": []string{}, "content": object{"text": marker}}, 35)
	report["worker_posted"] = posted != nil && posted["ok"] == true
	// A tool the worker's policy does not admit must be refused, proving the
	// child holds its own tools rather than the orchestrator's.
	forbidden := call("thread_launch", object{"definition_ref": "bee.harness.catalog:agent_launch_accepted_worker", "brief": "no", "idempotency_key": "worker-must-not-launch"}, 36)
	report["worker_launch_refused"] = forbidden == nil || forbidden["ok"] != true
}

// The scripted authoring agent. This function knows nothing about the
// application contract: it reads the overlay tool's guide index over the
// admitted MCP surface, requests the worked example explicitly, and authors
// exactly the file and the example text the guide returns. mode is "author"
// (author the guide example and request delivery) or "repair" (author only
// index.html and app.js, read the destination's refusal and remedy, then
// author the guide example into the same workspace and request delivery
// again), so the whole refusal -> remedy -> repair round is observed.
func reportAuthoring(client *httpClient, url, authorization string, report object, mode string) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	names, descriptions := toolsOf(rpc(client, url, authorization, "tools/list", object{}, 30))
	report["author_tools"] = names
	report["author_has_guide"] = false
	for _, item := range descriptions {
		if item["name"] == "overlay" {
			if text, ok := item["description"].(string); ok && strings.Contains(text, "guide") {
				report["author_has_guide"] = true
			}
		}
	}
	indexReply := call("overlay", object{"operation": "guide"}, 31)
	indexValue := mustObject(indexReply["value"])
	report["guide_revision"] = indexValue["revision"]
	report["guide_document"] = indexValue["document"]
	if sections, ok := indexValue["sections"].([]any); ok {
		report["guide_sections"] = len(sections)
	}
	guideReply := call("overlay", object{"operation": "guide", "include_example": true}, 31)
	guideValue := mustObject(guideReply["value"])
	example := mustObject(guideValue["example"])
	entriesJSON, _ := example["entries_json"].(string)
	report["guide_example_present"] = entriesJSON != ""

	workspace := os.Getenv("BEE_FIXTURE_AUTHOR_WORKSPACE")
	source := os.Getenv("BEE_FIXTURE_AUTHOR_SOURCE")
	version := os.Getenv("BEE_FIXTURE_AUTHOR_VERSION")
	destination := os.Getenv("BEE_FIXTURE_AUTHOR_DESTINATION")
	if workspace == "" || source == "" || version == "" || destination == "" {
		report["authoring_error"] = "authoring identities are missing"
		return
	}
	created := mustObject(call("overlay", object{"operation": "create", "overlay_id": workspace,
		"expected_revision": 0, "idempotency_key": "create-" + source}, 32)["value"])
	report["author_create_revision"] = created["revision"]

	if mode == "repair" {
		// Round 1: a workspace holding only index.html and app.js.
		call("overlay", object{"operation": "put", "overlay_id": workspace, "expected_revision": 1,
			"idempotency_key": "put-index-" + source, "path": "index.html", "content": "<html></html>"}, 33)
		call("overlay", object{"operation": "put", "overlay_id": workspace, "expected_revision": 2,
			"idempotency_key": "put-app-" + source, "path": "app.js", "content": "console.log(1)"}, 34)
		frozen := mustObject(call("overlay", object{"operation": "freeze", "overlay_id": workspace,
			"expected_revision": 3, "idempotency_key": "freeze-" + source}, 35)["value"])
		report["author_snapshot_digest"] = frozen["digest"]
		listed := mustObject(call("overlay", object{"operation": "list", "overlay_id": workspace}, 36)["value"])
		report["author_files"] = listed["files"]
		refused := call("delivery", object{"operation": "request", "workspace_id": destination,
			"source_overlay_id": source, "version": version, "snapshot_digest": frozen["digest"]}, 37)
		report["refusal_ok"] = refused["ok"]
		report["refusal_code"] = refused["code"]
		report["refusal_message"] = refused["message"]
		if value := mustObject(refused["value"]); value != nil {
			report["refusal_remedy"] = value["remedy"]
		}
		// Round 2: the agent repairs exactly what the refusal named.
		repairPut := call("overlay", object{"operation": "put", "overlay_id": workspace, "expected_revision": 3,
			"idempotency_key": "put-entries-" + source, "path": example["path"], "content": entriesJSON}, 38)
		var repaired any = nil
		if repairPut["ok"] == true {
			repairFreeze := mustObject(call("overlay", object{"operation": "freeze", "overlay_id": workspace,
				"expected_revision": 4, "idempotency_key": "freeze-repaired-" + source}, 39))
			if repairedValue := mustObject(repairFreeze["value"]); repairedValue != nil {
				repaired = repairedValue["digest"]
				report["repaired_snapshot_digest"] = repaired
			}
		}
		if repaired != nil {
			reportAuthorDelivery(call, report, destination, source, version, repaired)
		}
		return
	}

	call("overlay", object{"operation": "put", "overlay_id": workspace, "expected_revision": 1,
		"idempotency_key": "put-entries-" + source, "path": example["path"], "content": entriesJSON}, 33)
	frozen := mustObject(call("overlay", object{"operation": "freeze", "overlay_id": workspace,
		"expected_revision": 2, "idempotency_key": "freeze-" + source}, 40)["value"])
	report["author_snapshot_digest"] = frozen["digest"]
	reportAuthorDelivery(call, report, destination, source, version, frozen["digest"])
}

// The scripted agent for a written spec. A model reads the spec and writes
// entries.json; this client stands in for that model with the answer the
// acceptance supplies in BEE_FIXTURE_AUTHOR_ENTRIES, and otherwise uses only
// the admitted MCP tools an installed agent holds: the guide, its own overlay
// and a delivery request that names no workspace, so the destination is the
// binding's own. It reports the destination's verdict and the staged status.
func reportSpecAuthoring(client *httpClient, url, authorization string, report object) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	names, _ := toolsOf(rpc(client, url, authorization, "tools/list", object{}, 50))
	report["author_tools"] = names
	guideValue := mustObject(call("overlay", object{"operation": "guide", "section": "workspace"}, 51)["value"])
	section, _ := guideValue["text"].(string)
	report["guide_revision"] = guideValue["revision"]
	report["guide_names_rule"] = strings.Contains(section, "app.<overlay_id>:app")
	source := os.Getenv("BEE_FIXTURE_AUTHOR_SOURCE")
	version := os.Getenv("BEE_FIXTURE_AUTHOR_VERSION")
	entries, err := os.ReadFile(os.Getenv("BEE_FIXTURE_AUTHOR_ENTRIES"))
	if source == "" || version == "" || err != nil {
		report["authoring_error"] = "spec authoring inputs are missing"
		return
	}
	created := call("overlay", object{"operation": "create", "overlay_id": source,
		"expected_revision": 0, "idempotency_key": "create-" + source}, 52)
	report["create_ok"] = created["ok"]
	put := call("overlay", object{"operation": "put", "overlay_id": source, "expected_revision": 1,
		"idempotency_key": "put-entries-" + source, "path": "entries.json", "content": string(entries)}, 53)
	report["put_ok"] = put["ok"]
	frozen := mustObject(call("overlay", object{"operation": "freeze", "overlay_id": source,
		"expected_revision": 2, "idempotency_key": "freeze-" + source}, 54)["value"])
	snapshot := frozen["digest"]
	report["snapshot_digest"] = snapshot
	delivered := call("delivery", object{"operation": "request", "source_overlay_id": source,
		"version": version, "snapshot_digest": snapshot}, 55)
	report["delivery_ok"] = delivered["ok"]
	report["delivery_code"] = delivered["code"]
	report["delivery_message"] = delivered["message"]
	if value := mustObject(delivered["value"]); value != nil {
		report["delivery_ready"] = value["ready"]
		report["delivery_diagnostics"] = value["diagnostics"]
		report["delivery_plan_digest"] = value["plan_digest"]
		report["delivery_component"] = value["component"]
		report["delivery_remedy"] = value["remedy"]
		if steps, ok := value["human_steps"].([]any); ok {
			report["delivery_human_steps"] = len(steps)
		}
	}
	status := call("delivery", object{"operation": "status", "source_overlay_id": source, "version": version}, 56)
	report["status_ok"] = status["ok"]
	report["status_message"] = status["message"]
	if value := mustObject(status["value"]); value != nil {
		report["status_plan_digest"] = value["plan_digest"]
		report["status_selected"] = value["selected"]
	}
}

func reportAuthorDelivery(call func(string, object, int) object, report object, workspace, source, version string, snapshot any) {
	delivered := mustObject(call("delivery", object{"operation": "request", "workspace_id": workspace,
		"source_overlay_id": source, "version": version, "snapshot_digest": snapshot}, 41))
	report["delivery_diagnostic_reply"] = delivered
	value := mustObject(delivered["value"])
	if value != nil {
		report["delivery_ready"] = value["ready"]
		report["delivery_diagnostics"] = value["diagnostics"]
		report["delivery_human_steps"] = value["human_steps"]
	}
	// Report the frozen digest on the bound thread, the way any managed agent
	// hands its result back; the desktop harness reads it from there.
	marker := os.Getenv("BEE_FIXTURE_AUTHOR_MARKER")
	if marker != "" && snapshot != nil {
		if text, ok := snapshot.(string); ok {
			call("thread_message", object{"idempotency_key": "report-" + marker, "message_id": marker,
				"message_kind": "progress", "recipient_ids": []string{},
				"content": object{"text": text, "artifact_ref": text}}, 42)
		}
	}
}

func containsName(names []string, name string) bool {
	for _, item := range names {
		if item == name {
			return true
		}
	}
	return false
}

func toolsOf(listed rpcReply) ([]string, []object) {
	names := []string{}
	descriptions := []object{}
	result := mustObject(listed.body["result"])
	tools, ok := result["tools"].([]any)
	if !ok {
		return names, descriptions
	}
	for _, item := range tools {
		if name := stringField(item, "name"); name != "" {
			names = append(names, name)
			if object := mustObject(item); object != nil {
				descriptions = append(descriptions, object)
			}
		}
	}
	sort.Strings(names)
	return names, descriptions
}

// Exercise configurable MCP through the same projected credentials as the harness.
func reportSurface(client *httpClient, url, authorization string, report object) {
	call := func(name string, args object, id int) object {
		return outcome(rpc(client, url, authorization, "tools/call", object{"name": name, "arguments": args}, id))
	}
	report["surface_before"] = call("session", object{"operation": "read"}, 20)
	inactive := rpc(client, url, authorization, "tools/call", object{"name": "thread_wait", "arguments": object{"after_sequence": 0, "wait_ms": 1}}, 21)
	report["surface_inactive"] = inactive.body["error"]
	report["surface_selected"] = call("session", object{"operation": "select", "expected_revision": 1,
		"active_traits": []string{"research:read", "research:wait"}, "context": object{"experiment": "managed-one"}}, 22)
	report["surface_after"] = call("session", object{"operation": "read"}, 23)
	report["surface_dispatch"] = call("call_tool", object{"name": "thread_wait", "arguments": object{"after_sequence": 0, "wait_ms": 1}}, 24)
	report["surface_overwrite"] = call("session", object{"operation": "select", "expected_revision": 2,
		"active_traits": []string{"research:read"}, "context": object{"project": "foreign"}}, 25)
}

// The scripted peer sessions of the cross-session acceptance. Each finds the
// other among its workspace's running sessions. The waiter asks to be told
// when the sender's turn ends, tells the sender it is ready, and blocks in
// thread_wait until the sender's "go ahead" arrives, then until the notice
// does. The sender waits for "ready" and answers "go ahead". Every step uses
// only the gateway tools the session's own launch policy admits.
func reportPeer(url, authorization string, report object, role string) {
	ident := 100
	call := func(name string, args object) object {
		ident++
		return outcome(rpcWithTimeout(nil, url, authorization, "tools/call", object{"name": name, "arguments": args}, ident, 20*time.Second))
	}
	self, peer := "", ""
	for attempt := 0; attempt < 180 && (self == "" || peer == ""); attempt++ {
		listed := call("thread_sessions", object{})
		value := mustObject(listed["value"])
		sessions, _ := value["sessions"].([]any)
		report["sessions_seen"] = len(sessions)
		for _, raw := range sessions {
			item := mustObject(raw)
			if item["self"] == true {
				self = stringField(item, "session")
			} else if peer == "" {
				peer = stringField(item, "session")
				report["peer_thread"] = item["thread_id"]
				report["peer_title"] = item["title"]
			}
		}
		if self == "" || peer == "" {
			time.Sleep(500 * time.Millisecond)
		}
	}
	report["self"] = self
	report["peer"] = peer
	if self == "" || peer == "" {
		return
	}
	cursor := 0
	addressed := func(record object, sender string, text string) bool {
		if stringField(record, "kind") != "message" {
			return false
		}
		body := mustObject(record["body"])
		recipients, _ := body["recipient_action_ids"].([]any)
		mine := false
		for _, item := range recipients {
			if item == self {
				mine = true
			}
		}
		if !mine || (sender != "" && stringField(body, "sender_action_id") != sender) {
			return false
		}
		return text == "" || stringField(mustObject(body["content"]), "text") == text
	}
	// Reads the thread forward from the cursor, returning the first match.
	scan := func(match func(object) bool) object {
		for {
			read := mustObject(call("thread_read", object{"cursor": cursor, "limit": 64})["value"])
			records, _ := read["records"].([]any)
			for _, raw := range records {
				record := mustObject(raw)
				if sequence, ok := record["sequence"].(float64); ok {
					cursor = int(sequence)
				}
				if match(record) {
					return record
				}
			}
			if scanned, ok := read["scanned_through"].(float64); ok && int(scanned) > cursor {
				cursor = int(scanned)
			}
			if read["has_more"] != true {
				return nil
			}
		}
	}
	// Blocks in thread_wait past the cursor, then reads what moved the
	// thread; reports how the wait that preceded the match ended.
	await := func(match func(object) bool, prefix string) object {
		for waits := 1; waits <= 60; waits++ {
			started := time.Now()
			waited := mustObject(call("thread_wait", object{"after_sequence": cursor, "wait_ms": 5000})["value"])
			report[prefix+"_wait_status"] = waited["status"]
			report[prefix+"_wait_ms"] = time.Since(started).Milliseconds()
			report[prefix+"_waits"] = waits
			if found := scan(match); found != nil {
				return found
			}
		}
		return nil
	}
	// Each awaits from its thread's first record: the peer may address it as
	// soon as it lists this session, before this fixture reads anything, and
	// every match names its sender, recipient and text.
	switch role {
	case "waiter":
		notified := call("thread_notify", object{"session": peer, "idempotency_key": "notify-" + peer})
		report["notify_ok"] = notified["ok"]
		report["notify_state"] = mustObject(notified["value"])["state"]
		ready := call("thread_message", object{"idempotency_key": "ready-" + self, "message_id": "ready-" + self, "message_kind": "notification",
			"session": peer, "content": object{"text": "ready"}})
		report["ready_sent"] = ready["ok"]
		goAhead := await(func(record object) bool { return addressed(record, peer, "go ahead") }, "go_ahead")
		if goAhead == nil {
			return
		}
		report["go_ahead"] = stringField(mustObject(mustObject(goAhead["body"])["content"]), "text")
		report["go_ahead_sender"] = stringField(mustObject(goAhead["body"]), "sender_action_id")
		notice := await(func(record object) bool {
			return addressed(record, "", "") && strings.HasPrefix(stringField(mustObject(record["body"]), "message_id"), "notice:")
		}, "notice")
		if notice == nil {
			return
		}
		body := mustObject(notice["body"])
		report["notice_text"] = stringField(mustObject(body["content"]), "text")
		report["notice_outcome"] = body["outcome"]
		report["notice_cause_thread"] = stringField(mustObject(notice["causation"]), "thread_id")
	case "sender":
		ready := await(func(record object) bool { return addressed(record, peer, "ready") }, "ready")
		report["ready_seen"] = ready != nil
		if ready == nil {
			return
		}
		sent := call("thread_message", object{"idempotency_key": "go-ahead-" + self, "message_id": "go-ahead-" + self, "message_kind": "notification",
			"session": peer, "content": object{"text": "go ahead"}})
		report["go_ahead_sent"] = sent["ok"]
	}
}

// Two independently owned actions coordinate only through their own inbox
// tools. Each side blocks in the server wait on its own thread and reads
// its inbox after the wake; the reported wait status names the wake, so a
// reply that arrived by polling would fail the acceptance, not hide in it.
func reportInboxPeer(url, authorization string, report object, role string) {
	ident := 300
	call := func(name string, args object) object {
		ident++
		return outcome(rpcWithTimeout(nil, url, authorization, "tools/call", object{"name": name, "arguments": args}, ident, 20*time.Second))
	}
	var self, peer object
	for attempt := 0; attempt < 120 && (self == nil || peer == nil); attempt++ {
		listed := mustObject(call("session_directory", object{})["value"])
		items, _ := listed["peers"].([]any)
		for _, raw := range items {
			item := mustObject(raw)
			if item["self"] == true {
				self = item
			} else if peer == nil {
				peer = item
			}
		}
		if self == nil || peer == nil {
			time.Sleep(250 * time.Millisecond)
		}
	}
	if self == nil || peer == nil {
		report["directory_failed"] = true
		return
	}
	report["self"] = self["action_id"]
	report["peer"] = peer["action_id"]
	report["peer_address"] = peer["address"]
	report["peer_epoch"] = peer["grant_epoch"]
	awaitItem := func(kind string) object {
		cursor := 0
		for waits := 1; waits <= 12; waits++ {
			started := time.Now()
			waited := mustObject(call("thread_wait", object{"after_sequence": cursor, "wait_ms": 5000})["value"])
			report[kind+"_wait_status"] = waited["status"]
			report[kind+"_wait_ms"] = time.Since(started).Milliseconds()
			report[kind+"_waits"] = waits
			if moved, ok := waited["head_sequence"].(float64); ok {
				cursor = int(moved)
			}
			listed := mustObject(call("session_inbox", object{"after_sequence": 0, "limit": 64})["value"])
			items, _ := listed["items"].([]any)
			for _, raw := range items {
				item := mustObject(raw)
				if stringField(item, "message_kind") == kind {
					return item
				}
			}
		}
		return nil
	}
	if role == "inbox_waiter" {
		args := object{"address": peer["address"], "grant_epoch": peer["grant_epoch"], "idempotency_key": "inbox-hello", "message_id": "inbox-hello", "content": object{"text": "hello"}}
		first := call("session_send", args)
		report["sent_ok"] = first["ok"]
		report["sent"] = first["value"]
		replay := call("session_send", args)
		report["replayed"] = replay["replayed"]
		report["replay_record_id"] = mustObject(replay["value"])["record_id"]
		answer := awaitItem("reply")
		if answer == nil {
			report["reply_missing"] = true
			return
		}
		report["reply_text"] = stringField(mustObject(answer["content"]), "text")
		report["reply_record_id"] = answer["record_id"]
		report["reply_correlation"] = answer["in_reply_to"]
		report["ack_ok"] = call("session_ack", object{"inbox_sequence": answer["inbox_sequence"], "idempotency_key": "ack-reply"})["ok"]
	} else if role == "inbox_sender" {
		request := awaitItem("request")
		if request == nil {
			report["request_missing"] = true
			return
		}
		report["request_text"] = stringField(mustObject(request["content"]), "text")
		report["request_record_id"] = request["record_id"]
		report["ack_ok"] = call("session_ack", object{"inbox_sequence": request["inbox_sequence"], "idempotency_key": "ack-request"})["ok"]
		answered := call("session_reply", object{"address": peer["address"], "grant_epoch": peer["grant_epoch"], "idempotency_key": "inbox-reply", "message_id": "inbox-reply",
			"content": object{"text": "world"}, "in_reply_to": object{"thread_id": request["thread_id"], "record_id": request["record_id"]}, "outcome": "succeeded"})
		report["reply_ok"] = answered["ok"]
		report["reply"] = answered["value"]
	}
}

func reportWait(client *httpClient, url string, authorization string, report object, readValue object, waitMS int) {
	started := time.Now()
	head := 0
	if value := mustObject(readValue["value"]); value != nil {
		if scanned, ok := value["scanned_through"].(float64); ok {
			head = int(scanned)
		}
	}
	var status int
	var result object
	for attempt := 0; attempt < 12; attempt++ {
		reply := rpcWithTimeout(client, url, authorization, "tools/call", object{
			"name":      "thread_wait",
			"arguments": object{"after_sequence": head, "wait_ms": waitMS},
		}, 4+attempt, time.Duration(waitMS)*time.Millisecond+10*time.Second)
		status = reply.status
		value := outcome(reply)
		result = mustObject(value["value"])
		if status != http.StatusOK || result == nil || result["status"] != "ready" {
			break
		}
		// A ready watch reports the thread's head and leaves scanned_through
		// at the cursor it was given; the next wait starts from the head.
		if moved, ok := result["head_sequence"].(float64); ok {
			head = int(moved)
		}
	}
	report["wait"] = object{"status": status, "elapsed_ms": time.Since(started).Milliseconds(), "outcome": result}
}

func rpcWithTimeout(_ *httpClient, url string, authorization string, method string, params object, ident int, timeout time.Duration) rpcReply {
	return (&httpClient{client: &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{DisableKeepAlives: true},
	}}).post(url, authorization, object{
		"jsonrpc": "2.0",
		"id":      ident,
		"method":  method,
		"params":  params,
	})
}

// runHookPost posts a raw hook payload to a hook URL with its hook credential and
// reports the status line and body, so hook response contracts stay
// observable without a driver binary.
func runHookPost(args []string) int {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, "hookpost needs url, credential and body")
		return 2
	}
	raw, err := base64.StdEncoding.DecodeString(args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, "hookpost body:", err)
		return 2
	}
	var request *http.Request
	request, err = http.NewRequest("POST", args[0], bytes.NewReader(raw))
	if err != nil {
		fmt.Fprintln(os.Stderr, "hookpost request:", err)
		return 1
	}
	request.Header.Set("Authorization", "Bearer "+args[1])
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	var replied *http.Response
	replied, err = client.Do(request)
	if err != nil {
		fmt.Fprintln(os.Stderr, "hookpost post:", err)
		return 1
	}
	defer replied.Body.Close()
	var body []byte
	body, err = io.ReadAll(replied.Body)
	if err != nil {
		fmt.Fprintln(os.Stderr, "hookpost read:", err)
		return 1
	}
	fmt.Printf("hookpost_status=%d\nhookpost_body=%s\n", replied.StatusCode, strings.TrimSpace(string(body)))
	return 0
}

func writeReport(prefix string, report object) {
	encoded, err := json.Marshal(report)
	if err != nil {
		return
	}
	if os.Getenv("BEE_FIXTURE_REPORT_STREAM") == "1" {
		// Keep the fixture report ahead of the captured terminal envelope in
		// the same stdout stream. Stderr and stdout have no cross-pipe order.
		frame, frameErr := json.Marshal(object{"type": "system", "subtype": "informational",
			"level": "info", "content": prefix + ":" + string(encoded)})
		if frameErr == nil {
			fmt.Fprintln(os.Stdout, string(frame))
		}
		return
	}
	fmt.Fprintf(os.Stderr, "%s:%s\n", prefix, encoded)
}

type endpointRecord struct {
	Path          string   `json:"path"`
	Authorization string   `json:"authorization"`
	APIKey        string   `json:"x_api_key"`
	ContentType   string   `json:"content_type"`
	Messages      int      `json:"messages"`
	InputItems    int      `json:"input_items"`
	OffersBash    bool     `json:"offers_bash"`
	ToolResult    bool     `json:"tool_result"`
	MCPTools      []string `json:"mcp_tools"`
	ResultExcerpt string   `json:"result_excerpt"`
}

// endpoint is the controlled loopback provider used by the harness tests. It
// intentionally lives beside the other fixture clients so the harness pack
// contains no interpreter dependency. It records the request shape and either
// emits the small scripted Messages/Responses stream or a deterministic
// invalid-request response.
func endpoint(record string, hold time.Duration) error {
	toolCommand := os.Getenv("BEE_ENDPOINT_TOOL")
	mcpTool := os.Getenv("BEE_ENDPOINT_MCP_TOOL")
	plainText := os.Getenv("BEE_ENDPOINT_TEXT")

	messageStart := func(id string) object {
		return object{"type": "message_start", "message": object{"id": id, "type": "message", "role": "assistant", "model": "bee-endpoint", "content": []any{}, "stop_reason": nil, "stop_sequence": nil, "usage": object{"input_tokens": 10, "output_tokens": 1}}}
	}
	sse := func(events ...object) []byte {
		var out bytes.Buffer
		for _, event := range events {
			name, _ := event["event"].(string)
			payload, _ := json.Marshal(event["data"])
			fmt.Fprintf(&out, "event: %s\ndata: %s\n\n", name, payload)
		}
		return out.Bytes()
	}
	messageText := func(text string) []byte {
		return sse(
			object{"event": "message_start", "data": messageStart("msg_text")},
			object{"event": "content_block_start", "data": object{"type": "content_block_start", "index": 0, "content_block": object{"type": "text", "text": ""}}},
			object{"event": "content_block_delta", "data": object{"type": "content_block_delta", "index": 0, "delta": object{"type": "text_delta", "text": text}}},
			object{"event": "content_block_stop", "data": object{"type": "content_block_stop", "index": 0}},
			object{"event": "message_delta", "data": object{"type": "message_delta", "delta": object{"stop_reason": "end_turn", "stop_sequence": nil}, "usage": object{"output_tokens": 5}}},
			object{"event": "message_stop", "data": object{"type": "message_stop"}},
		)
	}
	mcpMessage := func(name, toolID string, arguments object) []byte {
		encoded, _ := json.Marshal(arguments)
		return sse(
			object{"event": "message_start", "data": messageStart("msg_mcp")},
			object{"event": "content_block_start", "data": object{"type": "content_block_start", "index": 0, "content_block": object{"type": "tool_use", "id": toolID, "name": name, "input": object{}}}},
			object{"event": "content_block_delta", "data": object{"type": "content_block_delta", "index": 0, "delta": object{"type": "input_json_delta", "partial_json": string(encoded)}}},
			object{"event": "content_block_stop", "data": object{"type": "content_block_stop", "index": 0}},
			object{"event": "message_delta", "data": object{"type": "message_delta", "delta": object{"stop_reason": "tool_use", "stop_sequence": nil}, "usage": object{"output_tokens": 20}}},
			object{"event": "message_stop", "data": object{"type": "message_stop"}},
		)
	}
	toolMessage := func(command string) []byte {
		return mcpMessage("Bash", "toolu_bee_1", object{"command": command, "description": "leave a marker"})
	}
	responses := func(item object, id string) []byte {
		return sse(
			object{"event": "response.created", "data": object{"type": "response.created", "response": object{"id": id, "object": "response", "status": "in_progress", "output": []any{}}}},
			object{"event": "response.output_item.added", "data": object{"type": "response.output_item.added", "output_index": 0, "item": item}},
			object{"event": "response.output_item.done", "data": object{"type": "response.output_item.done", "output_index": 0, "item": item}},
			object{"event": "response.completed", "data": object{"type": "response.completed", "response": object{"id": id, "object": "response", "status": "completed", "output": []object{item}, "usage": object{"input_tokens": 10, "output_tokens": 5, "total_tokens": 15}}}},
		)
	}
	responsesText := func(text string) []byte {
		return responses(object{"type": "message", "id": "msg_done", "role": "assistant", "status": "completed", "content": []object{{"type": "output_text", "text": text, "annotations": []any{}}}}, "resp_text")
	}

	server := &http.Server{}
	var requestMu sync.Mutex
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestMu.Lock()
		defer requestMu.Unlock()
		body, _ := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		var parsed object
		if json.Unmarshal(body, &parsed) != nil {
			parsed = object{}
		}
		messages, _ := parsed["messages"].([]any)
		tools, _ := parsed["tools"].([]any)
		inputs, _ := parsed["input"].([]any)
		offersBash := false
		mcpTools := []string{}
		for _, raw := range tools {
			tool, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			name, _ := tool["name"].(string)
			if name == "Bash" {
				offersBash = true
			}
			if strings.HasPrefix(name, "mcp__bee__") {
				mcpTools = append(mcpTools, strings.TrimPrefix(name, "mcp__bee__"))
			}
			if name == "mcp__bee" {
				if nested, ok := tool["tools"].([]any); ok {
					for _, innerRaw := range nested {
						if inner, ok := innerRaw.(map[string]any); ok {
							if nestedName, ok := inner["name"].(string); ok {
								mcpTools = append(mcpTools, nestedName)
							}
						}
					}
				}
			}
		}
		hasResult := false
		resultExcerpt := ""
		for _, raw := range messages {
			message, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if content, ok := message["content"].([]any); ok {
				for _, itemRaw := range content {
					item, ok := itemRaw.(map[string]any)
					if !ok || item["type"] != "tool_result" {
						continue
					}
					hasResult = true
					if blocks, ok := item["content"].([]any); ok {
						blockText := ""
						for _, blockRaw := range blocks {
							if block, ok := blockRaw.(map[string]any); ok {
								if text, ok := block["text"].(string); ok {
									blockText += text
								}
							}
						}
						if len(blockText) > 400 {
							blockText = blockText[:400]
						}
						resultExcerpt = blockText
					} else {
						resultExcerpt = fmt.Sprint(item["content"])
						if len(resultExcerpt) > 400 {
							resultExcerpt = resultExcerpt[:400]
						}
					}
				}
			}
		}
		for _, raw := range inputs {
			item, ok := raw.(map[string]any)
			if ok && item["type"] == "function_call_output" {
				hasResult = true
				resultExcerpt = fmt.Sprint(item["output"])
				if len(resultExcerpt) > 400 {
					resultExcerpt = resultExcerpt[:400]
				}
			}
		}
		recordEntry := endpointRecord{Path: r.URL.RequestURI(), Authorization: r.Header.Get("authorization"), APIKey: r.Header.Get("x-api-key"), ContentType: r.Header.Get("content-type"), Messages: len(messages), InputItems: len(inputs), OffersBash: offersBash, ToolResult: hasResult, MCPTools: mcpTools, ResultExcerpt: resultExcerpt}
		if file, err := os.OpenFile(record, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			encoded, _ := json.Marshal(recordEntry)
			_, _ = file.Write(append(encoded, '\n'))
			_ = file.Close()
		}
		if hold > 0 {
			time.Sleep(hold)
		}
		responsesAPI := strings.Contains(r.URL.RequestURI(), "/responses")
		var payload []byte
		status := http.StatusOK
		contentType := "text/event-stream"
		switch {
		case r.URL.Path == "/api/hello":
			contentType = "application/json"
			payload = []byte(`{"status":"ok"}`)
		case mcpTool != "":
			if responsesAPI {
				if hasResult {
					payload = responsesText("done")
				} else {
					payload = responses(object{"type": "function_call", "id": "fc_bee_mcp", "call_id": "call_bee_mcp", "name": mcpTool, "namespace": "mcp__bee", "arguments": `{"cursor":0}`, "status": "completed"}, "resp_mcp")
				}
			} else if hasResult {
				payload = messageText("done")
			} else {
				payload = mcpMessage("mcp__bee__"+mcpTool, "toolu_bee_mcp", object{"cursor": 0})
			}
		case plainText != "":
			if responsesAPI {
				payload = responsesText(plainText)
			} else {
				payload = messageText(plainText)
			}
		case toolCommand != "":
			if offersBash && !hasResult {
				payload = toolMessage(toolCommand)
			} else {
				payload = messageText("done")
			}
		default:
			status = http.StatusBadRequest
			contentType = "application/json"
			payload, _ = json.Marshal(object{"type": "error", "error": object{"message": "controlled endpoint", "type": "invalid_request_error"}})
		}
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		w.WriteHeader(status)
		_, _ = w.Write(payload)
	})
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := os.WriteFile(record+".port", []byte(strconv.Itoa(port)), 0o600); err != nil {
		_ = listener.Close()
		return err
	}
	go func() { _ = server.Serve(listener) }()
	stopping := make(chan os.Signal, 1)
	signal.Notify(stopping, syscall.SIGTERM, syscall.SIGINT)
	<-stopping
	signal.Stop(stopping)
	_ = server.Close()
	return nil
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "endpoint" {
		if len(os.Args) < 3 {
			return
		}
		hold := 0.0
		if len(os.Args) > 3 {
			hold, _ = strconv.ParseFloat(os.Args[3], 64)
		}
		if err := endpoint(os.Args[2], time.Duration(hold*float64(time.Second))); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) < 3 {
		return
	}
	var status int
	switch os.Args[1] {
	case "hooks":
		status = runHooks(os.Args[2])
	case "gateway":
		status = runGateway(os.Args[2])
	case "codex":
		status = runCodexGateway(os.Args[2])
	case "hookpost":
		status = runHookPost(os.Args[2:])
	}
	if status != 0 {
		os.Exit(status)
	}
}
