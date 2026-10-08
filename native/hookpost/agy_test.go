// SPDX-License-Identifier: MIT

package hookpost

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestAgyTranscriptBoundaries(t *testing.T) {
	fixtures := "../../tests/fixtures/drivers/agy/hooks-1"
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
