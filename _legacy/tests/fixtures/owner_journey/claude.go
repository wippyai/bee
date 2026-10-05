// SPDX-License-Identifier: MIT
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

const marker = "OWNER JOURNEY STUB OUTPUT"
const session = "owner-journey-fixture"

type object = map[string]interface{}

func emit(value object) {
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func assistant(text string) {
	emit(object{"type": "assistant", "message": object{"role": "assistant", "content": []object{{"type": "text", "text": text}}}})
}

func stageReview(arguments []string) error {
	var config struct {
		Servers map[string]struct {
			URL     string            `json:"url"`
			Headers map[string]string `json:"headers"`
		} `json:"mcpServers"`
	}
	for index, argument := range arguments {
		if argument == "--mcp-config" && index+1 < len(arguments) {
			if err := json.Unmarshal([]byte(arguments[index+1]), &config); err != nil {
				return fmt.Errorf("fixture MCP config: %w", err)
			}
			break
		}
	}
	server := config.Servers["bee"]
	endpoint, err := url.Parse(server.URL)
	if err != nil {
		return fmt.Errorf("fixture gateway URL: %w", err)
	}
	if endpoint.Hostname() != "127.0.0.1" && endpoint.Hostname() != "localhost" && endpoint.Hostname() != "::1" {
		return fmt.Errorf("fixture gateway must be loopback")
	}
	reference := regexp.MustCompile(`^Bearer \$\{([A-Za-z_][A-Za-z0-9_]*)\}$`).FindStringSubmatch(server.Headers["Authorization"])
	if reference == nil {
		return fmt.Errorf("fixture gateway requires an environment reference")
	}
	token, present := os.LookupEnv(reference[1])
	if !present || token == "" {
		return fmt.Errorf("fixture gateway environment reference is missing")
	}
	// The transport bound applies to one loopback request, not an approval wait.
	client := &http.Client{Timeout: 30 * time.Second}
	sequence := 0
	rpc := func(method string, params object, target interface{}) error {
		sequence++
		body, err := json.Marshal(object{"jsonrpc": "2.0", "id": sequence, "method": method, "params": params})
		if err != nil {
			return err
		}
		request, err := http.NewRequest(http.MethodPost, server.URL, bytes.NewReader(body))
		if err != nil {
			return err
		}
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Accept", "application/json")
		request.Header.Set("Authorization", "Bearer "+token)
		response, err := client.Do(request)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return fmt.Errorf("MCP HTTP %s", response.Status)
		}
		var reply struct {
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if err := json.NewDecoder(response.Body).Decode(&reply); err != nil {
			return err
		}
		if len(reply.Error) > 0 && string(reply.Error) != "null" {
			return fmt.Errorf("MCP %s", reply.Error)
		}
		return json.Unmarshal(reply.Result, target)
	}
	tool := func(name string, values object, target interface{}) error {
		var reply struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		}
		if err := rpc("tools/call", object{"name": name, "arguments": values}, &reply); err != nil {
			return err
		}
		if len(reply.Content) == 0 {
			return fmt.Errorf("%s: missing tool content", name)
		}
		var result struct {
			OK      bool            `json:"ok"`
			Value   json.RawMessage `json:"value"`
			Error   json.RawMessage `json:"error"`
			Code    string          `json:"code"`
			Message string          `json:"message"`
		}
		if err := json.Unmarshal([]byte(reply.Content[0].Text), &result); err != nil {
			return err
		}
		if !result.OK {
			if len(result.Error) > 0 && string(result.Error) != "null" {
				return fmt.Errorf("%s: %s", name, result.Error)
			}
			return fmt.Errorf("%s: %s: %s", name, result.Code, result.Message)
		}
		return json.Unmarshal(result.Value, target)
	}
	var initialized json.RawMessage
	if err := rpc("initialize", object{"protocolVersion": "2025-06-18", "capabilities": object{},
		"clientInfo": object{"name": "owner-journey-fixture", "version": "1"}}, &initialized); err != nil {
		return err
	}
	var guide struct {
		Example struct {
			Path    string `json:"path"`
			Entries string `json:"entries_json"`
		} `json:"example"`
	}
	if err := tool("overlay", object{"operation": "guide", "include_example": true}, &guide); err != nil {
		return err
	}
	var revision json.RawMessage
	if err := tool("overlay", object{"operation": "create", "overlay_id": "counter",
		"expected_revision": 0, "idempotency_key": "hive-create"}, &revision); err != nil {
		return err
	}
	if err := tool("overlay", object{"operation": "put", "overlay_id": "counter", "expected_revision": 1,
		"idempotency_key": "hive-put", "path": guide.Example.Path, "content": guide.Example.Entries}, &revision); err != nil {
		return err
	}
	var frozen struct {
		Digest string `json:"digest"`
	}
	if err := tool("overlay", object{"operation": "freeze", "overlay_id": "counter",
		"expected_revision": 2, "idempotency_key": "hive-freeze"}, &frozen); err != nil {
		return err
	}
	var staged struct {
		Ready       bool            `json:"ready"`
		Diagnostics json.RawMessage `json:"diagnostics"`
	}
	if err := tool("delivery", object{"operation": "request", "source_overlay_id": "counter",
		"version": "1.0.0", "snapshot_digest": frozen.Digest}, &staged); err != nil {
		return err
	}
	if !staged.Ready {
		return fmt.Errorf("native review preflight: %s", staged.Diagnostics)
	}
	assistant("OWNER JOURNEY REVIEW STAGED")
	return nil
}

func run(arguments []string) error {
	if len(arguments) > 0 {
		switch arguments[0] {
		case "--version":
			fmt.Println("2.1.265")
			return nil
		case "--help":
			fmt.Println("--permission-mode --model --effort --append-system-prompt-file")
			return nil
		case "auth":
			emit(object{"loggedIn": true, "authMethod": "fixture"})
			return nil
		}
	}
	emit(object{"type": "system", "subtype": "init", "session_id": session})
	for _, argument := range arguments {
		if strings.Contains(argument, "JOURNEY_HIVE_APPROVAL") {
			if err := stageReview(arguments); err != nil {
				return err
			}
			break
		}
	}
	for _, argument := range arguments {
		if index := strings.LastIndex(argument, "JOURNEY_GATE="); index >= 0 {
			gate := argument[index+len("JOURNEY_GATE="):]
			if !strings.Contains(gate, "/.wippy/") {
				return fmt.Errorf("fixture release FIFO must be under .wippy")
			}
			release, err := os.Open(gate)
			if err != nil {
				return fmt.Errorf("fixture release FIFO: %w", err)
			}
			_, err = bufio.NewReader(release).ReadBytes('\n')
			release.Close()
			if err != nil {
				return fmt.Errorf("fixture release FIFO: %w", err)
			}
		}
	}
	assistant(marker)
	emit(object{"type": "result", "subtype": "success", "is_error": false, "result": marker,
		"session_id": session, "usage": object{"input_tokens": 1, "output_tokens": 1}})
	return nil
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Owner journey fixture failed:", err)
		emit(object{"type": "result", "subtype": "error", "is_error": true, "result": err.Error(), "session_id": session})
		os.Exit(1)
	}
}
