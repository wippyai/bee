//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import "testing"

func TestLaunchedApplicationFencesIdentityAndRejectsInventedSuccess(t *testing.T) {
	mounted := DesktopMount{Selection: selection, Session: "session", Mode: Control, lifetime: make(chan struct{})}
	value := func() map[string]any {
		return map[string]any{"owner_execution": selection.Execution, "workspace_id": selection.Workspace, "desktop_id": selection.Desktop, "session_id": "session", "id": "view-1", "instance_id": "instance-1"}
	}
	result, err := DecodeLaunchedApplication(desktopReply(t, value()), mounted)
	if err != nil || result.ID != "view-1" || result.Instance != "instance-1" {
		t.Fatalf("valid broker reply: %+v %v", result, err)
	}
	for _, field := range []string{"owner_execution", "workspace_id", "desktop_id", "session_id", "id", "instance_id"} {
		missing := value()
		delete(missing, field)
		if _, err := DecodeLaunchedApplication(desktopReply(t, missing), mounted); err == nil {
			t.Fatalf("missing %s accepted", field)
		}
		changed := value()
		changed[field] = ""
		if _, err := DecodeLaunchedApplication(desktopReply(t, changed), mounted); err == nil {
			t.Fatalf("empty %s accepted", field)
		}
	}
	foreign := value()
	foreign["session_id"] = "replacement"
	if _, err := DecodeLaunchedApplication(desktopReply(t, foreign), mounted); err == nil {
		t.Fatal("replacement session accepted")
	}
	extra := value()
	extra["grant"] = "admin"
	if _, err := DecodeLaunchedApplication(desktopReply(t, extra), mounted); err == nil {
		t.Fatal("extra authority accepted")
	}
	stale := make(chan struct{})
	close(stale)
	mounted.lifetime = stale
	if _, err := DecodeLaunchedApplication(desktopReply(t, value()), mounted); err == nil {
		t.Fatal("retired mount accepted")
	}
}
