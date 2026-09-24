//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/runtime/api/pid"
)

var selection = DesktopSelection{Execution: strings.Repeat("a", 32), Workspace: strings.Repeat("b", 32), Desktop: strings.Repeat("c", 32)}
var desktopRecipient = pid.PID{Node: "client", Host: mesh.ActorHost, UniqID: "one"}
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
	for field, wrong := range map[string]any{"owner_execution": strings.Repeat("d", 32), "workspace_id": strings.Repeat("d", 32), "desktop_id": strings.Repeat("d", 32), "session_id": "", "recipient": "{other@" + mesh.ActorHost + "|one}", "mode": "observe", "mount_ref": "bad\x00mount", "expires_at": "2026-09-09T12:00:00.000Z", "extra": true} {
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
func catalogValue() map[string]any {
	return map[string]any{"owner_execution": selection.Execution,
		"desktops": []any{map[string]any{"desktop_id": selection.Desktop, "is_default": true},
			map[string]any{"desktop_id": strings.Repeat("e", 32), "is_default": false}},
		"workspaces": []any{
			map[string]any{"workspace_id": selection.Workspace, "label": "Alpha", "served": true},
			map[string]any{"workspace_id": strings.Repeat("d", 32), "label": "", "served": false}},
		"next_after":        "cursor",
		"default_workspace": selection.Workspace}
}

func TestDesktopCatalogListsNodeDisplaysOnceAndOnePageOfWorkspaces(t *testing.T) {
	catalog, err := DecodeDesktopCatalog(desktopReply(t, catalogValue()), selection.Execution)
	if err != nil || len(catalog.Workspaces) != 2 || len(catalog.Desktops) != 2 || catalog.Next != "cursor" ||
		catalog.Default != selection.Workspace || !catalog.Workspaces[0].Served || catalog.Workspaces[1].Served {
		t.Fatalf("catalog: %+v %v", catalog, err)
	}
	last := catalogValue()
	delete(last, "next_after")
	delete(last, "default_workspace")
	last["workspaces"] = map[string]any{}
	if decoded, err := DecodeDesktopCatalog(desktopReply(t, last), selection.Execution); err != nil || decoded.Next != "" || decoded.Default != "" || len(decoded.Workspaces) != 0 {
		t.Fatalf("Lua empty page refused: %+v %v", decoded, err)
	}
	for name, change := range map[string]func(map[string]any){
		"null workspaces":   func(v map[string]any) { v["workspaces"] = nil },
		"object workspaces": func(v map[string]any) { v["workspaces"] = map[string]any{"extra": true} },
		"no displays":       func(v map[string]any) { v["desktops"] = map[string]any{} },
		"second default":    func(v map[string]any) { v["desktops"].([]any)[1].(map[string]any)["is_default"] = true },
		"duplicate display": func(v map[string]any) { v["desktops"].([]any)[1].(map[string]any)["desktop_id"] = selection.Desktop },
		"duplicate workspace": func(v map[string]any) {
			v["workspaces"].([]any)[1].(map[string]any)["workspace_id"] = selection.Workspace
		},
		"label control": func(v map[string]any) { v["workspaces"].([]any)[0].(map[string]any)["label"] = "a\x1b[2J" },
		"workspace alias": func(v map[string]any) {
			w := v["workspaces"].([]any)[0].(map[string]any)
			w["WORKSPACE_ID"] = w["workspace_id"]
			delete(w, "workspace_id")
		},
		"empty cursor":      func(v map[string]any) { v["next_after"] = "" },
		"invalid default":   func(v map[string]any) { v["default_workspace"] = "short" },
		"extra field":       func(v map[string]any) { v["extra"] = true },
		"foreign execution": func(v map[string]any) { v["owner_execution"] = strings.Repeat("f", 32) },
	} {
		value := catalogValue()
		change(value)
		if _, err := DecodeDesktopCatalog(desktopReply(t, value), selection.Execution); err == nil {
			t.Fatal("accepted malformed catalog:", name)
		}
	}
}
func TestDesktopCreatedRequiresExactAllocationReceipt(t *testing.T) {
	value := map[string]any{"owner_execution": selection.Execution, "desktop_id": selection.Desktop}
	if err := DecodeDesktopCreated(desktopReply(t, value), selection.Execution, selection.Desktop); err != nil {
		t.Fatal(err)
	}
	for field, wrong := range map[string]any{
		"owner_execution": strings.Repeat("d", 32),
		"desktop_id":      strings.Repeat("d", 32),
		"workspace_id":    selection.Workspace,
	} {
		changed := map[string]any{"owner_execution": selection.Execution, "desktop_id": selection.Desktop}
		changed[field] = wrong
		if DecodeDesktopCreated(desktopReply(t, changed), selection.Execution, selection.Desktop) == nil {
			t.Fatalf("accepted changed %s", field)
		}
	}
	closed := make(chan struct{})
	close(closed)
	reply := desktopReply(t, value)
	reply.lifetime = closed
	if DecodeDesktopCreated(reply, selection.Execution, selection.Desktop) == nil {
		t.Fatal("accepted creation after owner lifetime ended")
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

// After a switch the display's controller holds a session on another
// workspace: the same execution, display, recipient and mode.
func TestDesktopCurrentFollowsItsDisplayIntoAnotherWorkspace(t *testing.T) {
	moved := strings.Repeat("d", 32)
	value := mountValue()
	value["workspace_id"] = moved
	value["session_id"] = "session-2"
	value["mount_ref"] = "moved-mount"
	current, err := DecodeDesktopCurrent(desktopReply(t, value), selection.Execution, selection.Desktop, desktopRecipient, Control, desktopNow)
	if err != nil || current.Selection.Workspace != moved || current.Selection.Desktop != selection.Desktop || current.Session != "session-2" || current.Mount != "moved-mount" {
		t.Fatalf("current=%+v error=%v", current, err)
	}
	for field, wrong := range map[string]any{"owner_execution": strings.Repeat("e", 32), "desktop_id": strings.Repeat("e", 32),
		"workspace_id": "short", "recipient": "{other@" + mesh.ActorHost + "|one}", "mode": "observe"} {
		t.Run("wrong_"+field, func(t *testing.T) {
			changed := mountValue()
			changed[field] = wrong
			if _, err := DecodeDesktopCurrent(desktopReply(t, changed), selection.Execution, selection.Desktop, desktopRecipient, Control, desktopNow); err == nil {
				t.Fatal("accepted substitution")
			}
		})
	}
}
