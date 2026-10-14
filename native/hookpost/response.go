// SPDX-License-Identifier: MIT

package hookpost

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

type extensionOutput struct {
	Event    string                     `json:"hookEventName"`
	Context  *string                    `json:"additionalContext,omitempty"`
	Decision *string                    `json:"permissionDecision,omitempty"`
	Reason   *string                    `json:"permissionDecisionReason,omitempty"`
	Input    map[string]json.RawMessage `json:"updatedInput,omitempty"`
	Output   json.RawMessage            `json:"updatedToolOutput,omitempty"`
}
type extensionEnvelope struct {
	Decision *string          `json:"decision,omitempty"`
	Reason   *string          `json:"reason,omitempty"`
	Specific *extensionOutput `json:"hookSpecificOutput,omitempty"`
}

func decodeResponse(data []byte, target any) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || data[0] != '{' {
		return errors.New("hook-post: response must be an object")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(target) != nil {
		return errors.New("hook-post: invalid hook response")
	}
	var extra json.RawMessage
	if decoder.Decode(&extra) != io.EOF {
		return errors.New("hook-post: multiple response documents")
	}
	return nil
}
func extensionResponse(data []byte, stdout io.Writer, event string, agy bool) error {
	if stdout == nil {
		return errors.New("hook-post: stdout is required")
	}
	if agy {
		return agyResponse(data, stdout, event)
	}
	var response extensionEnvelope
	if err := decodeResponse(data, &response); err != nil {
		return err
	}
	valid := true
	if response.Decision != nil || response.Reason != nil {
		valid = event == "UserPromptSubmit" && response.Decision != nil && *response.Decision == "block" && response.Reason != nil && len(*response.Reason) > 0 && len(*response.Reason) <= 4096
	}
	if out := response.Specific; out != nil {
		valid = valid && out.Event == event
		if out.Context != nil {
			valid = valid && len(*out.Context) > 0 && len(*out.Context) <= 24576
		}
		if out.Decision != nil || out.Reason != nil {
			valid = valid && event == "PreToolUse" && out.Decision != nil
			if out.Decision != nil {
				switch *out.Decision {
				case "deny":
					valid = valid && out.Reason != nil && len(*out.Reason) > 0 && len(*out.Reason) <= 4096 && out.Input == nil
				case "allow":
					valid = valid && out.Input != nil && out.Reason == nil
				default:
					valid = false
				}
			}
		}
		if out.Input != nil {
			valid = valid && event == "PreToolUse"
		}
		if out.Output != nil {
			valid = valid && event == "PostToolUse"
		}
		valid = valid && (out.Context != nil || out.Decision != nil || out.Input != nil || out.Output != nil)
	}
	if !valid {
		return errors.New("hook-post: invalid hook response")
	}
	_, err := stdout.Write(append(bytes.TrimSpace(data), '\n'))
	return err
}
func agyResponse(data []byte, stdout io.Writer, event string) error {
	var response struct {
		Decision  *string                    `json:"decision,omitempty"`
		Reason    *string                    `json:"reason,omitempty"`
		Overwrite map[string]json.RawMessage `json:"overwrite,omitempty"`
		Steps     []struct {
			Message string `json:"ephemeralMessage"`
		} `json:"injectSteps,omitempty"`
	}
	if err := decodeResponse(data, &response); err != nil {
		return err
	}
	valid := true
	if response.Decision != nil || response.Reason != nil {
		valid = event == "PreToolUse" && response.Decision != nil && *response.Decision == "deny" && response.Reason != nil && len(*response.Reason) > 0 && len(*response.Reason) <= 4096 && response.Overwrite == nil
	}
	if response.Overwrite != nil {
		valid = valid && event == "PreToolUse"
	}
	if response.Steps != nil {
		valid = valid && event == "UserPromptSubmit" && len(response.Steps) == 1 && len(response.Steps[0].Message) > 0 && len(response.Steps[0].Message) <= 24576
	}
	if !valid {
		return errors.New("hook-post: invalid Agy response")
	}
	_, err := stdout.Write(append(bytes.TrimSpace(data), '\n'))
	return err
}
