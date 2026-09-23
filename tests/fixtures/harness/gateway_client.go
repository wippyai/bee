// MIT. Standard-library HTTP clients used by the Claude fixture executable.
// This is test-fixture code and is compiled into bin/gateway-client before the
// fixture directory is copied into an isolated test workspace.
package main

import (
	"bytes"
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

func runGateway(mcpLiteral string) int {
	url, authorization, ok := mcpConfig(mcpLiteral)
	if !ok {
		return 0
	}
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
	if marker := os.Getenv("BEE_FIXTURE_GATEWAY_WORKER"); marker != "" {
		reportWorker(client, url, authorization, report, marker)
	}
	if os.Getenv("BEE_FIXTURE_GATEWAY_AUTHOR") != "" {
		reportAuthoring(client, url, authorization, report, os.Getenv("BEE_FIXTURE_GATEWAY_AUTHOR"))
	}
	if os.Getenv("BEE_FIXTURE_GATEWAY_APP_OPEN") != "" {
		reportApplicationOpen(client, url, authorization, report)
	}
	if os.Getenv("BEE_FIXTURE_GATEWAY_SURFACE") == "1" {
		reportSurface(client, url, authorization, report)
	}
	if waitMS, err := strconv.Atoi(os.Getenv("BEE_FIXTURE_GATEWAY_WAIT")); err == nil && waitMS > 0 {
		reportWait(client, url, authorization, report, readValue, waitMS)
	}
	if hold, err := strconv.ParseFloat(os.Getenv("BEE_FIXTURE_GATEWAY_HOLD"), 64); err == nil && hold > 0 {
		timer := time.NewTimer(time.Duration(hold * float64(time.Second)))
		select {
		case <-timer.C:
		case <-stopping:
			if !timer.Stop() {
				<-timer.C
			}
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
	launched := call("thread_launch", object{"definition_ref": definition, "brief": brief, "idempotency_key": "k"}, 30)
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
// application contract: it reads the overlay tool's guide operation over the
// admitted MCP surface and authors exactly the file and the example text the
// guide returns, so a contract change is visible here without editing this
// client. mode is "author" (author the guide example and request delivery) or
// "repair" (author only index.html and app.js, read the destination's refusal
// and remedy, then author the guide example into the same workspace and request
// delivery again), so the whole refusal -> remedy -> repair round is observed.
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
	guideReply := call("overlay", object{"operation": "guide"}, 31)
	guideValue := mustObject(guideReply["value"])
	example := mustObject(guideValue["example"])
	entriesJSON, _ := example["entries_json"].(string)
	report["guide_revision"] = guideValue["revision"]
	report["guide_document"] = guideValue["document"]
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

func writeReport(prefix string, report object) {
	encoded, err := json.Marshal(report)
	if err != nil {
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
	}
	if status != 0 {
		os.Exit(status)
	}
}
