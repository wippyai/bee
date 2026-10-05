//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/client/mesh"
)

func workspacesFixture(t *testing.T) (*Workspaces, *scripted) {
	t.Helper()
	client, s, _ := fixture(t)
	return WorkspacesOver(client), s
}

func workspaceRow(id, state string) map[string]any {
	return map[string]any{"workspace_id": id, "label": "Second", "root_ref": "bee.env:workspace_root", "subpath": "second", "state": state,
		"created_at": "2026-09-24T00:00:00.000Z", "last_used_at": "2026-09-24T00:00:00.000Z"}
}

func TestWorkspacesCallTheWorkspaceServiceOfTheOwner(t *testing.T) {
	w, s := workspacesFixture(t)
	id := strings.Repeat("a", 32)
	done := make(chan wireCall, 1)
	go func() {
		call := <-s.body
		done <- call
		raw, _ := json.Marshal(map[string]any{"protocol_revision": Revision, "request_id": call.ID, "ok": true, "grants": map[string]any{},
			"value": workspaceRow(id, "active")})
		s.replies <- mesh.Message{From: ownerPID, Topic: replyTopic, Body: raw}
	}()
	row, err := w.Create(callContext(t), NewWorkspace{Label: "Second", Root: "bee.env:workspace_root", Subpath: "second", CreateDirectory: true})
	if err != nil || row.ID != id || row.Folder() != "bee.env:workspace_root/second" {
		t.Fatalf("create = %+v, %v", row, err)
	}
	call := <-done
	if call.Owner.Service != WorkspaceService || call.Owner.Node != "owner" || call.Target.Ref != WorkspaceCreate ||
		string(call.Input) != `{"label":"Second","root_ref":"bee.env:workspace_root","subpath":"second","create_directory":true}` || len(call.Key) != 32 {
		t.Fatalf("call = %+v", call)
	}
}

func TestWorkspacesDecodeTheCatalogAnswers(t *testing.T) {
	w, s := workspacesFixture(t)
	id := strings.Repeat("b", 32)
	answer(s, map[string]any{"items": []any{workspaceRow(id, "active")}, "next_after": id + ":61"}, nil)
	page, err := w.List(callContext(t), "active", "", 50)
	if err != nil || len(page.Items) != 1 || page.Items[0].ID != id || page.Next != id+":61" {
		t.Fatalf("list = %+v, %v", page, err)
	}
	// The Lua exporter spells an empty list as {}.
	answer(s, map[string]any{"items": map[string]any{}}, nil)
	if page, err := w.List(callContext(t), "archived", "", 50); err != nil || len(page.Items) != 0 || page.Next != "" {
		t.Fatalf("empty list = %+v, %v", page, err)
	}
	answer(s, map[string]any{"roots": []any{map[string]any{"root_ref": "bee.env:workspace_root", "access": "write"}}}, nil)
	roots, err := w.Roots(callContext(t))
	if err != nil || len(roots) != 1 || roots[0].Access != "write" {
		t.Fatalf("roots = %+v, %v", roots, err)
	}
	answer(s, workspaceRow(id, "archived"), nil)
	if row, err := w.Archive(callContext(t), id); err != nil || row.State != "archived" {
		t.Fatalf("archive = %+v, %v", row, err)
	}
	answer(s, nil, map[string]any{"code": "INVALID_STATE", "message": "BUSY: workspace host is running", "retryable": false})
	_, err = w.Archive(callContext(t), id)
	var rejected *Rejected
	if !errors.As(err, &rejected) || rejected.Fault.Code != "INVALID_STATE" {
		t.Fatalf("busy archive = %v", err)
	}
	answer(s, workspaceRow("not-an-id", "active"), nil)
	if _, err := w.Restore(callContext(t), id); !errors.Is(err, ErrProtocol) {
		t.Fatalf("invalid row accepted: %v", err)
	}
	answer(s, map[string]any{"roots": []any{map[string]any{"root_ref": "bee:x", "access": "all"}}}, nil)
	if _, err := w.Roots(callContext(t)); !errors.Is(err, ErrProtocol) {
		t.Fatalf("invalid access accepted: %v", err)
	}
}

func TestWorkspaceRowsAndCursorsMatchTheirTypedContract(t *testing.T) {
	valid := Workspace{ID: strings.Repeat("a", 32), Label: "Project", Root: "bee.env:workspace_root", Subpath: "src",
		State: WorkspaceActive, CreatedAt: "2026-09-24T00:00:00.000Z", LastUsed: "2026-09-24T00:00:00.000Z"}
	for name, change := range map[string]func(*Workspace){
		"control-label":     func(row *Workspace) { row.Label = "bad\nlabel" },
		"invalid-subpath":   func(row *Workspace) { row.Subpath = "../outside" },
		"invalid-created":   func(row *Workspace) { row.CreatedAt = "2026-09-24T00:00:00Z" },
		"invalid-last-used": func(row *Workspace) { row.LastUsed = "not-time" },
		"unknown-state":     func(row *Workspace) { row.State = "deleted" },
	} {
		t.Run(name, func(t *testing.T) {
			row := valid
			change(&row)
			if validWorkspace(row) {
				t.Fatalf("accepted malformed workspace row: %+v", row)
			}
		})
	}
	for _, cursor := range []string{
		"short", valid.ID + ":A", valid.ID + ":abc", valid.ID + ":61:" + "zz",
		valid.ID + ":" + strings.Repeat("a", maxCursorBytes),
	} {
		if validWorkspaceCursor(cursor) {
			t.Errorf("accepted invalid workspace cursor %q", cursor)
		}
	}
	if !validWorkspaceCursor(valid.ID + ":61:" + "6265652e656e763a776f726b73706163655f726f6f74") {
		t.Fatal("rejected canonical multi-root cursor")
	}
}
