// SPDX-License-Identifier: MIT

package hookpost

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAgyTranscriptBoundaries(t *testing.T) {
	fixtures := "../../drivers/test/fixtures/drivers/agy/hooks-1"
	artifact := filepath.Join(t.TempDir(), "brain", "ef06ab43-51b5-4911-8a6f-f4700e9a3193")
	transcript := filepath.Join(artifact, ".system_generated", "logs", "transcript_full.jsonl")
	if err := os.MkdirAll(filepath.Dir(transcript), 0700); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(fixtures, "transcript.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(transcript, data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ native, event, field, text string }{
		{"PreInvocation", "UserPromptSubmit", "prompt", "Fixture prompt."},
		{"Stop", "Stop", "last_assistant_message", "Fixture answer."},
	} {
		t.Run(tc.native, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(fixtures, tc.native+".json"))
			if err != nil {
				t.Fatal(err)
			}
			var fields map[string]any
			if err := json.Unmarshal(raw, &fields); err != nil {
				t.Fatal(err)
			}
			fields["artifactDirectoryPath"] = artifact
			fields["transcriptPath"] = transcript
			raw, _ = json.Marshal(fields)
			result, err := agyPayload(raw, tc.event)
			if err != nil {
				t.Fatal(err)
			}
			var got map[string]any
			if err := json.Unmarshal(result, &got); err != nil {
				t.Fatal(err)
			}
			if got[tc.field] != tc.text || got["session_id"] != fields["conversationId"] {
				t.Fatalf("unexpected boundary: %v", got)
			}
			if tc.native == "PreInvocation" {
				fields["invocationNum"] = 1
				raw, _ = json.Marshal(fields)
				result, err = agyPayload(raw, tc.event)
				if err != nil || result != nil {
					t.Fatalf("model continuation accepted as work: %s %v", result, err)
				}
			}
			fields["invocationNum"] = 0
			fields["transcriptPath"] = filepath.Join(artifact, "auth.json")
			raw, _ = json.Marshal(fields)
			if _, err := agyPayload(raw, tc.event); err == nil {
				t.Fatal("accepted an unrelated file")
			}
		})
	}
}

func TestAgyTranscriptRejectsEscapesAndIncompleteStops(t *testing.T) {
	artifact := filepath.Join(t.TempDir(), "fixture-session")
	transcript := filepath.Join(artifact, ".system_generated", "logs", "transcript_full.jsonl")
	if err := os.MkdirAll(filepath.Dir(transcript), 0700); err != nil {
		t.Fatal(err)
	}
	fields := map[string]any{"conversationId": "fixture-session", "artifactDirectoryPath": artifact,
		"transcriptPath": transcript, "fullyIdle": true, "error": ""}
	for _, content := range []string{
		`{"step_index":0,"type":"USER_INPUT","source":"USER_EXPLICIT","status":"DONE","content":"Fixture prompt."}` + "\n",
		`{"step_index":0,"type":"USER_INPUT","source":"USER_EXPLICIT","status":"DONE","content":"Fixture prompt."}` + "\n" + `{"step_index":1,"type":"PLANNER_RESPONSE","status":"ACTIVE","content":"unfinished"}` + "\n",
		`{broken`,
	} {
		if err := os.WriteFile(transcript, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		raw, _ := json.Marshal(fields)
		if _, err := agyPayload(raw, "Stop"); err == nil {
			t.Fatal("incomplete transcript settled successfully")
		}
	}
	outside := filepath.Join(t.TempDir(), "outside.jsonl")
	if err := os.WriteFile(outside, []byte("not a transcript"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(transcript); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, transcript); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(fields)
	if _, err := agyPayload(raw, "Stop"); err == nil {
		t.Fatal("transcript escaped its artifact root")
	}
	fields["fullyIdle"] = false
	raw, _ = json.Marshal(fields)
	if _, err := agyPayload(raw, "Stop"); err == nil {
		t.Fatal("active provider settled successfully")
	}
}

func writeAgyTranscript(t *testing.T, lines []string, padding int) (string, string) {
	t.Helper()
	artifact := filepath.Join(t.TempDir(), "conversation-1")
	transcript := filepath.Join(artifact, ".system_generated", "logs", "transcript_full.jsonl")
	if err := os.MkdirAll(filepath.Dir(transcript), 0700); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(transcript)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	filler := `{"step_index":%d,"source":"MODEL","type":"GENERIC","status":"DONE","content":"` + strings.Repeat("x", 50000) + `"}` + "\n"
	for index := 0; index < padding; index++ {
		if _, err := fmt.Fprintf(file, filler, index); err != nil {
			t.Fatal(err)
		}
	}
	for _, line := range lines {
		if _, err := file.WriteString(line + "\n"); err != nil {
			t.Fatal(err)
		}
	}
	return artifact, transcript
}

func agyHook(t *testing.T, artifact, transcript string, fields map[string]any) []byte {
	t.Helper()
	fields["conversationId"] = "conversation-1"
	fields["artifactDirectoryPath"] = artifact
	fields["transcriptPath"] = transcript
	raw, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// A resumed conversation keeps its whole history in the transcript; the
// boundary reads the current turn from its end.
func TestAgyTranscriptOfALongResumedConversation(t *testing.T) {
	const padding = 800
	artifact, transcript := writeAgyTranscript(t, []string{
		`{"step_index":800,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nwe back\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nlocal time\n</ADDITIONAL_METADATA>"}`,
		`{"step_index":801,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"ephemeral"}`,
	}, padding)
	if info, err := os.Stat(transcript); err != nil || info.Size() <= 32<<20 {
		t.Fatalf("transcript must exceed one turn's bound: %v", err)
	}
	result, err := agyPayload(agyHook(t, artifact, transcript, map[string]any{"invocationNum": 0, "initialNumSteps": 802}), "UserPromptSubmit")
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(result, &got); err != nil || got["prompt"] != "we back" || got["prompt_id"] != "800" {
		t.Fatalf("unexpected prompt boundary: %s %v", result, err)
	}
	file, err := os.OpenFile(transcript, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(`{"step_index":802,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Welcome back."}` + "\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()
	result, err = agyPayload(agyHook(t, artifact, transcript, map[string]any{"fullyIdle": true, "error": ""}), "Stop")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(result, &got); err != nil || got["last_assistant_message"] != "Welcome back." || got["prompt_id"] != "800" {
		t.Fatalf("unexpected stop boundary: %s %v", result, err)
	}
}

// An invocation the model starts after it already answered the latest prompt
// carries no new prompt.
func TestAgyInvocationAfterAnAnsweredPromptIsNoPrompt(t *testing.T) {
	artifact, transcript := writeAgyTranscript(t, []string{
		`{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"Fixture prompt."}`,
		`{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Started."}`,
		`{"step_index":2,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"background command finished"}`,
	}, 0)
	result, err := agyPayload(agyHook(t, artifact, transcript, map[string]any{"invocationNum": 0, "initialNumSteps": 3}), "UserPromptSubmit")
	if err != nil || result != nil {
		t.Fatalf("an answered prompt became new work: %s %v", result, err)
	}
}
