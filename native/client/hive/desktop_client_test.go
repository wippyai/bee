//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
)

func desktopBinding(t *testing.T) (*Desktop, *scripted) {
	c, s, _ := fixture(t)
	return &Desktop{client: c, owner: "owner", execution: selection.Execution, recipient: desktopRecipient}, s
}
func answerDesktop(s *scripted, value any, fault *Fault) wireCall {
	call := <-s.body
	body := map[string]any{"protocol_revision": Revision, "request_id": call.ID, "ok": fault == nil, "grants": []any{}}
	if fault != nil {
		body["error"] = fault
	} else {
		body["value"] = value
	}
	raw, _ := json.Marshal(body)
	s.replies <- mesh.Message{From: ownerPID, Topic: replyTopic, Body: raw}
	return call
}
func TestDesktopBindingCarriesExactIdentityAndUsesOneSendPerOperation(t *testing.T) {
	d, s := desktopBinding(t)
	value := mountValue()
	value["expires_at"] = time.Now().UTC().Add(time.Minute).Format(desktopTimeLayout)
	calls := make(chan wireCall, 1)
	go func() { calls <- answerDesktop(s, value, nil) }()
	mounted, err := d.Attach(context.Background(), "attach-key", selection.Workspace, selection.Desktop, Control)
	if err != nil {
		t.Fatal(err)
	}
	call := <-calls
	if call.Key != "attach-key" || call.Owner.Node != "owner" || call.Owner.Service != DesktopService || call.Target.Ref != DesktopAttach {
		t.Fatalf("wrong operation: %+v", call)
	}
	var input struct {
		DesktopSelection
		Mode DesktopMode `json:"mode"`
	}
	if err := json.Unmarshal(call.Input, &input); err != nil || input.DesktopSelection != selection || input.Mode != Control {
		t.Fatalf("wrong input: %s", call.Input)
	}
	ack := map[string]any{"owner_execution": selection.Execution, "workspace_id": selection.Workspace, "desktop_id": selection.Desktop, "detached": true}
	go func() { calls <- answerDesktop(s, ack, nil) }()
	if err := d.Detach(context.Background(), "detach-key", mounted); err != nil {
		t.Fatal(err)
	}
	detached := <-calls
	var detachInput struct {
		DesktopSelection
		Session string `json:"session_id"`
	}
	if json.Unmarshal(detached.Input, &detachInput) != nil || detachInput.Session != mounted.Session || detached.Key != "detach-key" || detached.Target.Ref != DesktopDetach {
		t.Fatalf("wrong detach: %+v", detached)
	}
	if s.sent.Load() != 2 {
		t.Fatal("operation replayed")
	}
	mounted.owner = "foreign"
	if d.Detach(context.Background(), "bad", mounted) == nil || s.sent.Load() != 2 {
		t.Fatal("foreign-owner mount sent")
	}
}

const desktopTimeLayout = "2006-01-02T15:04:05.000Z"

func TestDesktopBindingDistinguishesRefusalFromUnknownSuccessfulGrant(t *testing.T) {
	for _, scenario := range []string{"denied", "uncertain", "malformed"} {
		t.Run(scenario, func(t *testing.T) {
			d, s := desktopBinding(t)
			var fault *Fault
			if scenario == "denied" {
				fault = &Fault{Code: "DENIED", Message: "host denied", Retryable: false}
			}
			if scenario == "uncertain" {
				fault = &Fault{Code: "UNCERTAIN", Message: "completion unknown", Retryable: false}
			}
			go answerDesktop(s, map[string]any{}, fault)
			_, err := d.Attach(context.Background(), "retained-key", selection.Workspace, selection.Desktop, Control)
			if err == nil {
				t.Fatal("failure accepted")
			}
			var unknown *UnknownOutcome
			if scenario == "denied" {
				var rejected *Rejected
				if !errors.As(err, &rejected) || errors.As(err, &unknown) {
					t.Fatalf("wrong refusal: %v", err)
				}
			} else if !errors.As(err, &unknown) || unknown.Key != "retained-key" || unknown.Operation != DesktopAttach {
				t.Fatalf("lost uncertainty: %v", err)
			}
			if s.sent.Load() != 1 {
				t.Fatal("replayed attach")
			}
		})
	}
}
func TestDesktopBindingRejectsInvalidSelectionBeforeSend(t *testing.T) {
	d, s := desktopBinding(t)
	if _, err := d.Attach(context.Background(), "key", "foreign", selection.Desktop, Control); err == nil {
		t.Fatal("bad identity")
	}
	if _, err := d.Attach(context.Background(), "key", selection.Workspace, selection.Desktop, "admin"); err == nil {
		t.Fatal("bad mode")
	}
	if s.sent.Load() != 0 {
		t.Fatal("invalid selection sent")
	}
}

func TestDesktopCreateRetainsIdentityAndUncertainty(t *testing.T) {
	for _, malformed := range []bool{false, true} {
		d, s := desktopBinding(t)
		calls := make(chan wireCall, 1)
		value := selection
		if malformed {
			value.Desktop = "wrong"
		}
		go func() { calls <- answerDesktop(s, value, nil) }()
		created, err := d.Create(context.Background(), selection.Workspace, selection.Desktop)
		call := <-calls
		var input DesktopSelection
		if call.Key != selection.Desktop || call.Target.Ref != DesktopCreate || json.Unmarshal(call.Input, &input) != nil || input != selection {
			t.Fatalf("allocation lost its retained identity: %+v", call)
		}
		if malformed {
			var unknown *UnknownOutcome
			if !errors.As(err, &unknown) || unknown.Key != selection.Desktop || unknown.Operation != DesktopCreate {
				t.Fatalf("allocation uncertainty lost: %v", err)
			}
		} else if err != nil || created != selection {
			t.Fatalf("created=%+v err=%v", created, err)
		}
		if s.sent.Load() != 1 {
			t.Fatal("allocation replayed")
		}
		if _, err := d.Create(context.Background(), "invalid", selection.Desktop); err == nil || s.sent.Load() != 1 {
			t.Fatal("invalid creation was sent")
		}
	}
}
