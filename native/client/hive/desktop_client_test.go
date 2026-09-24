//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
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

func TestDesktopBindingCreatesExactDurableIdentityBeforeAttachment(t *testing.T) {
	d, s := desktopBinding(t)
	calls := make(chan wireCall, 1)
	go func() {
		calls <- answerDesktop(s, map[string]any{
			"owner_execution": selection.Execution,
			"desktop_id":      selection.Desktop,
		}, nil)
	}()
	created, err := d.Create(context.Background(), selection.Desktop)
	if err != nil || created != selection.Desktop {
		t.Fatalf("creation=%+v error=%v", created, err)
	}
	call := <-calls
	if call.Key != selection.Desktop || call.Target.Ref != DesktopCreate || call.Owner.Node != "owner" || call.Owner.Service != DesktopService {
		t.Fatalf("wrong creation operation: %+v", call)
	}
	var input map[string]string
	if json.Unmarshal(call.Input, &input) != nil || len(input) != 2 || input["owner_execution"] != selection.Execution || input["desktop_id"] != selection.Desktop {
		t.Fatalf("wrong creation input: %s", call.Input)
	}
	if _, err := d.Create(context.Background(), "foreign"); err == nil || s.sent.Load() != 1 {
		t.Fatal("invalid creation was sent")
	}
}

func TestDesktopBindingListsOnePageByLabelAndCursor(t *testing.T) {
	d, s := desktopBinding(t)
	calls := make(chan wireCall, 1)
	go func() {
		calls <- answerDesktop(s, map[string]any{
			"owner_execution": selection.Execution,
			"desktops":        []any{map[string]any{"desktop_id": selection.Desktop, "is_default": true}},
			"workspaces":      []any{map[string]any{"workspace_id": selection.Workspace, "label": "Alpha", "served": true}},
			"next_after":      "cursor-2",
		}, nil)
	}()
	catalog, err := d.List(context.Background(), "list-key", CatalogQuery{Label: "al", After: "cursor-1"})
	if err != nil || len(catalog.Workspaces) != 1 || catalog.Next != "cursor-2" || catalog.Workspaces[0].Label != "Alpha" {
		t.Fatalf("catalog=%+v error=%v", catalog, err)
	}
	call := <-calls
	var input map[string]string
	if call.Target.Ref != DesktopList || json.Unmarshal(call.Input, &input) != nil || len(input) != 3 ||
		input["label"] != "al" || input["after"] != "cursor-1" || input["owner_execution"] != selection.Execution {
		t.Fatalf("wrong list input: %s", call.Input)
	}
	if _, err := d.List(context.Background(), "bad", CatalogQuery{Label: "bad\x1b"}); err == nil || s.sent.Load() != 1 {
		t.Fatal("control text sent as a query")
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

func TestDesktopBindingReadsTheCurrentSessionOfItsDisplay(t *testing.T) {
	d, s := desktopBinding(t)
	value := mountValue()
	value["expires_at"] = time.Now().UTC().Add(time.Minute).Format(desktopTimeLayout)
	go answerDesktop(s, value, nil)
	mounted, err := d.Attach(context.Background(), "attach-key", selection.Workspace, selection.Desktop, Control)
	if err != nil {
		t.Fatal(err)
	}
	moved := mountValue()
	moved["workspace_id"] = strings.Repeat("d", 32)
	moved["session_id"] = "session-2"
	moved["expires_at"] = value["expires_at"]
	calls := make(chan wireCall, 1)
	go func() { calls <- answerDesktop(s, moved, nil) }()
	current, err := d.Current(context.Background(), "current-key", mounted)
	if err != nil || current.Selection.Workspace != strings.Repeat("d", 32) || current.Session != "session-2" {
		t.Fatalf("current=%+v error=%v", current, err)
	}
	call := <-calls
	var input map[string]string
	if call.Target.Ref != DesktopCurrent || json.Unmarshal(call.Input, &input) != nil || len(input) != 1 || input["owner_execution"] != selection.Execution {
		t.Fatalf("wrong current input: %s", call.Input)
	}
	mounted.owner = "foreign"
	if _, err := d.Current(context.Background(), "bad", mounted); err == nil || s.sent.Load() != 2 {
		t.Fatal("foreign-owner mount sent")
	}
}
