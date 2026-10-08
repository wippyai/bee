// SPDX-License-Identifier: MIT

package hookpost

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func agyPayload(raw []byte, event string) ([]byte, error) {
	var hook struct {
		Conversation string `json:"conversationId"`
		Artifact     string `json:"artifactDirectoryPath"`
		Transcript   string `json:"transcriptPath"`
		Invocation   int    `json:"invocationNum"`
		InitialSteps int    `json:"initialNumSteps"`
		FullyIdle    bool   `json:"fullyIdle"`
		Error        string `json:"error"`
		Tool         *struct {
			Name string         `json:"name"`
			Args map[string]any `json:"args"`
		} `json:"toolCall"`
	}
	if err := json.Unmarshal(raw, &hook); err != nil || !safeSegment(hook.Conversation, 160) {
		return nil, errors.New("hook-post: invalid Agy hook identity")
	}
	if event == "PermissionRequest" {
		if hook.Tool == nil || !safeSegment(hook.Tool.Name, 128) || hook.Tool.Args == nil {
			return nil, errors.New("hook-post: invalid Agy permission request")
		}
		body, err := json.Marshal(map[string]any{"session_id": hook.Conversation, "tool_name": hook.Tool.Name,
			"tool_input": hook.Tool.Args, "hook_event_name": event})
		if err != nil || len(body) > MaxPayloadBytes {
			return nil, errors.New("hook-post: Agy permission request exceeds its bound")
		}
		return body, nil
	}
	if event == "UserPromptSubmit" && hook.Invocation != 0 {
		return nil, nil
	}
	if event == "Stop" && (!hook.FullyIdle || hook.Error != "") {
		return nil, errors.New("hook-post: Agy turn did not complete")
	}
	if !filepath.IsAbs(hook.Artifact) || filepath.Base(hook.Artifact) != hook.Conversation ||
		hook.Transcript != filepath.Join(hook.Artifact, ".system_generated", "logs", "transcript_full.jsonl") {
		return nil, errors.New("hook-post: invalid Agy transcript path")
	}
	root, err := os.OpenRoot(hook.Artifact)
	if err != nil {
		return nil, errors.New("hook-post: Agy transcript unavailable")
	}
	defer root.Close()
	file, err := root.Open(".system_generated/logs/transcript_full.jsonl")
	if err != nil {
		return nil, errors.New("hook-post: Agy transcript unavailable")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 32<<20 {
		return nil, errors.New("hook-post: Agy transcript exceeds its bound")
	}
	scanner := bufio.NewScanner(io.LimitReader(file, 32<<20))
	scanner.Buffer(make([]byte, 65536), 1<<20)
	var prompt, answer string
	var promptIndex int
	for scanner.Scan() {
		var step struct {
			Index   int    `json:"step_index"`
			Source  string `json:"source"`
			Type    string `json:"type"`
			Status  string `json:"status"`
			Content string `json:"content"`
		}
		if json.Unmarshal(scanner.Bytes(), &step) != nil {
			return nil, errors.New("hook-post: invalid Agy transcript record")
		}
		if step.Type == "USER_INPUT" && step.Source == "USER_EXPLICIT" && step.Status == "DONE" {
			prompt = step.Content
			const start = "<USER_REQUEST>\n"
			if strings.HasPrefix(prompt, start) {
				end := strings.Index(prompt[len(start):], "\n</USER_REQUEST>")
				if end < 0 {
					return nil, errors.New("hook-post: invalid Agy prompt record")
				}
				prompt = prompt[len(start) : len(start)+end]
			}
			promptIndex = step.Index
			answer = ""
		}
		if step.Type == "PLANNER_RESPONSE" && step.Status == "DONE" {
			answer = step.Content
		}
	}
	if scanner.Err() != nil {
		return nil, errors.New("hook-post: unreadable Agy transcript")
	}
	if prompt == "" || len(prompt) > 24576 {
		return nil, errors.New("hook-post: Agy prompt is unavailable or exceeds its bound")
	}
	body := map[string]any{"session_id": hook.Conversation, "prompt_id": strconv.Itoa(promptIndex), "hook_event_name": event}
	if event == "UserPromptSubmit" {
		if promptIndex != hook.InitialSteps-1 {
			return nil, nil
		}
		body["prompt"] = prompt
	} else if event == "Stop" {
		if answer == "" || len(answer) > 24576 {
			return nil, errors.New("hook-post: Agy answer is unavailable or exceeds its bound")
		}
		body["last_assistant_message"] = answer
	} else {
		return nil, errors.New("hook-post: unsupported Agy transcript event")
	}
	encoded, err := json.Marshal(body)
	if err != nil || len(encoded) > MaxPayloadBytes {
		return nil, errors.New("hook-post: Agy boundary exceeds its bound")
	}
	return bytes.TrimSpace(encoded), nil
}
