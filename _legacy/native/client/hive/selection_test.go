//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func selectionValue() map[string]any {
	return map[string]any{"owner_execution": selection.Execution, "workspace_id": selection.Workspace,
		"desktop_id": selection.Desktop, "session_id": "session", "selected": true, "text": "界é\t\ntext"}
}

func TestCopyUsesExistingCallAndRejectsForeignRecipientBeforeSending(t *testing.T) {
	client, actor, _ := fixture(t)
	desktop := &Desktop{client: client, owner: "owner", execution: selection.Execution, recipient: desktopRecipient}
	mounted := DesktopMount{Selection: selection, Session: "session", Recipient: desktopRecipient,
		Expires: time.Now().Add(time.Minute), lifetime: client.ctx.Done(), owner: "owner"}
	foreign := mounted
	foreign.Recipient.UniqID = "replacement"
	if _, err := desktop.Copy(callContext(t), "foreign", foreign); err == nil {
		t.Fatal("foreign recipient copied")
	}
	if actor.sent.Load() != 0 {
		t.Fatal("foreign copy was sent")
	}
	go func() {
		call := <-actor.body
		if call.Target.Ref != DesktopCopy {
			t.Error("wrong operation", call.Target.Ref)
		}
		var input map[string]string
		if json.Unmarshal(call.Input, &input) != nil || input["session_id"] != mounted.Session || len(input) != 4 {
			t.Error("copy did not bind exact session", string(call.Input))
		}
		response := reply(call.ID)
		var wire map[string]any
		_ = json.Unmarshal(response.Body, &wire)
		wire["value"] = selectionValue()
		response.Body, _ = json.Marshal(wire)
		actor.replies <- response
	}()
	result, err := desktop.Copy(callContext(t), "copy-one", mounted)
	if err != nil || !result.Selected || result.Text != "界é\t\ntext" {
		t.Fatalf("copy: %#v %v", result, err)
	}
	if actor.sent.Load() != 1 {
		t.Fatal("copy replayed")
	}
}

func TestCopyReplyFencesSessionAndRejectsUnsafeText(t *testing.T) {
	mountReply := desktopReply(t, mountValue())
	lifetime := make(chan struct{})
	mountReply.lifetime = lifetime
	mounted, err := DecodeDesktopMount(mountReply, selection, desktopRecipient, Control, desktopNow)
	if err != nil {
		t.Fatal(err)
	}
	if result, err := DecodeSelectionText(desktopReply(t, selectionValue()), mounted, desktopNow); err != nil || !result.Selected || result.Text != "界é\t\ntext" {
		t.Fatalf("valid selection: %#v %v", result, err)
	}
	for _, field := range []string{"owner_execution", "workspace_id", "desktop_id", "session_id"} {
		value := selectionValue()
		value[field] = "replacement"
		if _, err := DecodeSelectionText(desktopReply(t, value), mounted, desktopNow); err == nil {
			t.Fatal("accepted substituted", field)
		}
	}
	for _, text := range []string{strings.Repeat("x", 8193), "\x1b]52;c;injected\a", "\r", "\x00", "\x7f"} {
		value := selectionValue()
		value["text"] = text
		if _, err := DecodeSelectionText(desktopReply(t, value), mounted, desktopNow); err == nil {
			t.Fatal("accepted unsafe selection")
		}
	}
	value := selectionValue()
	value["selected"] = false
	if _, err := DecodeSelectionText(desktopReply(t, value), mounted, desktopNow); err == nil {
		t.Fatal("unselected reply carried text")
	}
	value["text"] = ""
	if result, err := DecodeSelectionText(desktopReply(t, value), mounted, desktopNow); err != nil || result.Selected {
		t.Fatal("ordinary Ctrl+C refused", err)
	}
	if _, err := DecodeSelectionText(desktopReply(t, selectionValue()), mounted, mounted.Expires); err == nil {
		t.Fatal("expired attachment copied")
	}
	close(lifetime)
	if _, err := DecodeSelectionText(desktopReply(t, selectionValue()), mounted, desktopNow); err == nil {
		t.Fatal("retired attachment copied")
	}
}
