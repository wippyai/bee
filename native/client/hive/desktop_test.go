//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/pid"
)

var selection = DesktopSelection{Execution: strings.Repeat("a", 32), Workspace: strings.Repeat("b", 32), Desktop: strings.Repeat("c", 32)}
var desktopRecipient = pid.PID{Node: "client", Host: "bee.client:native", UniqID: "one"}
var desktopNow = time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)

func mountValue() map[string]any {
	return map[string]any{"owner_execution": selection.Execution, "workspace_id": selection.Workspace, "desktop_id": selection.Desktop,
		"session_id": "session", "recipient": desktopRecipient.String(), "mode": "control", "mount_ref": "native-mount", "expires_at": "2026-09-09T12:01:00.000Z"}
}
func desktopReply(t *testing.T, value any) Reply {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return Reply{OK: true, Value: raw, lifetime: make(chan struct{})}
}
func TestDesktopMountRejectsSubstitutedAuthorityAndMalformedFields(t *testing.T) {
	good := desktopReply(t, mountValue())
	mounted, err := DecodeDesktopMount(good, selection, desktopRecipient, Control, desktopNow)
	if err != nil || mounted.Session != "session" || mounted.Selection != selection || mounted.Done() != good.lifetime {
		t.Fatalf("valid mount: %+v %v", mounted, err)
	}
	for _, field := range []string{"owner_execution", "workspace_id", "desktop_id", "session_id", "recipient", "mode", "mount_ref", "expires_at"} {
		t.Run("missing_"+field, func(t *testing.T) {
			value := mountValue()
			delete(value, field)
			if _, err := DecodeDesktopMount(desktopReply(t, value), selection, desktopRecipient, Control, desktopNow); err == nil {
				t.Fatal("accepted absent field")
			}
		})
		t.Run("null_"+field, func(t *testing.T) {
			value := mountValue()
			value[field] = nil
			if _, err := DecodeDesktopMount(desktopReply(t, value), selection, desktopRecipient, Control, desktopNow); err == nil {
				t.Fatal("accepted null field")
			}
		})
		t.Run("alias_"+field, func(t *testing.T) {
			value := mountValue()
			value[strings.ToUpper(field)] = value[field]
			delete(value, field)
			if _, err := DecodeDesktopMount(desktopReply(t, value), selection, desktopRecipient, Control, desktopNow); err == nil {
				t.Fatal("accepted case alias")
			}
		})
	}
	for field, wrong := range map[string]any{"owner_execution": strings.Repeat("d", 32), "workspace_id": strings.Repeat("d", 32), "desktop_id": strings.Repeat("d", 32), "session_id": "", "recipient": "{other@bee.client:native|one}", "mode": "observe", "mount_ref": "bad\x00mount", "expires_at": "2026-09-09T12:00:00.000Z", "extra": true} {
		t.Run("wrong_"+field, func(t *testing.T) {
			value := mountValue()
			value[field] = wrong
			if _, err := DecodeDesktopMount(desktopReply(t, value), selection, desktopRecipient, Control, desktopNow); err == nil {
				t.Fatal("accepted substitution")
			}
		})
	}
	for _, raw := range []string{`null`, `[]`, `{}`, string(good.Value[:len(good.Value)-1]) + `,"mode":"control"}`} {
		r := good
		r.Value = json.RawMessage(raw)
		if _, err := DecodeDesktopMount(r, selection, desktopRecipient, Control, desktopNow); err == nil {
			t.Fatal("accepted malformed root or duplicate")
		}
	}
	for _, r := range []Reply{{OK: true, Value: good.Value}, {OK: false, Value: good.Value, lifetime: good.lifetime}, {OK: true, Value: good.Value, lifetime: good.lifetime, Grants: []Grant{{ID: "unexpected"}}}} {
		if _, err := DecodeDesktopMount(r, selection, desktopRecipient, Control, desktopNow); err == nil {
			t.Fatal("accepted unavailable/failed/grant reply")
		}
	}
	closed := make(chan struct{})
	close(closed)
	good.lifetime = closed
	if _, err := DecodeDesktopMount(good, selection, desktopRecipient, Control, desktopNow); err == nil {
		t.Fatal("accepted closed lifetime")
	}
}
func TestDesktopCatalogPreservesIndependentWorkspaceIdentities(t *testing.T) {
	value := map[string]any{"owner_execution": selection.Execution, "workspaces": []any{
		map[string]any{"workspace_id": selection.Workspace, "desktops": []any{map[string]any{"desktop_id": selection.Desktop}}},
		map[string]any{"workspace_id": strings.Repeat("d", 32), "desktops": map[string]any{}}}}
	catalog, err := DecodeDesktopCatalog(desktopReply(t, value), selection.Execution)
	if err != nil || len(catalog.Workspaces) != 2 || len(catalog.Workspaces[1].Desktops) != 0 {
		t.Fatalf("catalog: %+v %v", catalog, err)
	}
	for _, raw := range []string{
		`{"owner_execution":"` + selection.Execution + `","workspaces":null}`,
		`{"owner_execution":"` + selection.Execution + `","workspaces":{"extra":true}}`,
		`{"owner_execution":"` + selection.Execution + `","workspaces":[{"workspace_id":"` + selection.Workspace + `","desktops":[{"DESKTOP_ID":"` + selection.Desktop + `"}]}]}`,
		`{"owner_execution":"` + selection.Execution + `","workspaces":[{"workspace_id":"` + selection.Workspace + `","desktops":[{"desktop_id":"` + selection.Desktop + `"},{"desktop_id":"` + selection.Desktop + `"}]}]}`,
	} {
		r := desktopReply(t, value)
		r.Value = json.RawMessage(raw)
		if _, err := DecodeDesktopCatalog(r, selection.Execution); err == nil {
			t.Fatal("accepted malformed catalog", raw)
		}
	}
	empty := desktopReply(t, map[string]any{"owner_execution": selection.Execution, "workspaces": map[string]any{}})
	if _, err := DecodeDesktopCatalog(empty, selection.Execution); err != nil {
		t.Fatal("Lua empty list refused", err)
	}
}
func TestDesktopDetachRequiresExactSelectionAndPositiveAcknowledgment(t *testing.T) {
	value := map[string]any{"owner_execution": selection.Execution, "workspace_id": selection.Workspace, "desktop_id": selection.Desktop, "detached": true}
	if err := DecodeDesktopDetached(desktopReply(t, value), selection); err != nil {
		t.Fatal(err)
	}
	value["detached"] = false
	if DecodeDesktopDetached(desktopReply(t, value), selection) == nil {
		t.Fatal("false acknowledgment accepted")
	}
	value["detached"] = true
	value["workspace_id"] = strings.Repeat("d", 32)
	if DecodeDesktopDetached(desktopReply(t, value), selection) == nil {
		t.Fatal("foreign workspace accepted")
	}
}
