// SPDX-License-Identifier: MIT

package hookpost

import (
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
		Step         *int   `json:"stepIdx"`
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
	if event == "PermissionRequest" || event == "PreToolUse" {
		if hook.Tool == nil || !safeSegment(hook.Tool.Name, 128) || hook.Tool.Args == nil {
			return nil, errors.New("hook-post: invalid Agy permission request")
		}
		fields := map[string]any{"session_id": hook.Conversation, "tool_name": hook.Tool.Name,
			"tool_input": hook.Tool.Args, "hook_event_name": event}
		if event == "PreToolUse" {
			if hook.Step == nil || *hook.Step < 0 {
				return nil, errors.New("hook-post: invalid Agy tool occurrence")
			}
			fields["tool_call_id"] = strconv.Itoa(*hook.Step)
		}
		body, err := json.Marshal(fields)
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
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("hook-post: Agy transcript unavailable")
	}
	// The transcript holds the whole conversation; the current turn is read
	// from its end back to the latest prompt.
	var prompt, answer string
	var promptIndex int
	found, taken, answered := false, false, false
	err = readLinesBackward(file, info.Size(), func(line []byte) (bool, error) {
		var step struct {
			Index   int    `json:"step_index"`
			Source  string `json:"source"`
			Type    string `json:"type"`
			Status  string `json:"status"`
			Content string `json:"content"`
		}
		if json.Unmarshal(line, &step) != nil {
			return false, errors.New("hook-post: invalid Agy transcript record")
		}
		if event == "UserPromptSubmit" && step.Index >= hook.InitialSteps {
			return true, nil
		}
		if step.Type == "USER_INPUT" && step.Source == "USER_EXPLICIT" && step.Status == "DONE" {
			prompt, promptIndex, found = step.Content, step.Index, true
			return false, nil
		}
		if step.Source == "MODEL" {
			// A model step after the latest prompt means the model already
			// took it: this invocation continues earlier work.
			if event == "UserPromptSubmit" {
				taken = true
				return false, nil
			}
			if step.Type == "PLANNER_RESPONSE" && step.Status == "DONE" && !answered {
				answer, answered = step.Content, true
			}
		}
		return true, nil
	})
	if err != nil {
		return nil, err
	}
	if taken {
		return nil, nil
	}
	if found {
		const start = "<USER_REQUEST>\n"
		if strings.HasPrefix(prompt, start) {
			end := strings.Index(prompt[len(start):], "\n</USER_REQUEST>")
			if end < 0 {
				return nil, errors.New("hook-post: invalid Agy prompt record")
			}
			prompt = prompt[len(start) : len(start)+end]
		}
	}
	if !found || prompt == "" || len(prompt) > 24576 {
		return nil, errors.New("hook-post: Agy prompt is unavailable or exceeds its bound")
	}
	body := map[string]any{"session_id": hook.Conversation, "prompt_id": strconv.Itoa(promptIndex), "hook_event_name": event}
	if event == "UserPromptSubmit" {
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

const (
	maxTranscriptLine = 1 << 20
	maxTranscriptTurn = 32 << 20
)

// readLinesBackward hands each line of the file's first size bytes to visit,
// last line first, until visit stops or the file begins. One turn may span at
// most maxTranscriptTurn bytes and one record maxTranscriptLine bytes.
func readLinesBackward(file io.ReaderAt, size int64, visit func([]byte) (bool, error)) error {
	const chunk = 64 << 10
	var pending []byte
	offset := size
	for {
		for {
			cut := bytes.LastIndexByte(pending, '\n')
			if cut < 0 {
				break
			}
			line := pending[cut+1:]
			pending = pending[:cut]
			if len(bytes.TrimSpace(line)) == 0 {
				continue
			}
			more, err := visit(line)
			if err != nil || !more {
				return err
			}
		}
		if len(pending) > maxTranscriptLine {
			return errors.New("hook-post: Agy transcript record exceeds its bound")
		}
		if offset == 0 {
			if len(bytes.TrimSpace(pending)) == 0 {
				return nil
			}
			_, err := visit(pending)
			return err
		}
		if size-offset >= maxTranscriptTurn {
			return errors.New("hook-post: Agy turn exceeds its transcript bound")
		}
		read := int64(chunk)
		if offset < read {
			read = offset
		}
		offset -= read
		buffer := make([]byte, int(read)+len(pending))
		if _, err := file.ReadAt(buffer[:read], offset); err != nil && err != io.EOF {
			return errors.New("hook-post: unreadable Agy transcript")
		}
		copy(buffer[read:], pending)
		pending = buffer
	}
}
