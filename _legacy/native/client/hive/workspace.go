//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"strings"
	"unicode/utf8"
)

// The workspace commands of the owner supervisor
// (src/hive/supervisor/workspace_commands.lua). Each runs one operation of the
// node workspace catalog; the owner authorizes it under its host's policy.
const (
	WorkspaceService = "bee.workspace"
	WorkspaceCreate  = "bee.workspace:create"
	WorkspaceList    = "bee.workspace:list"
	WorkspaceArchive = "bee.workspace:archive"
	WorkspaceRestore = "bee.workspace:restore"
	WorkspaceRoots   = "bee.workspace:roots"
)

// Workspace is one row of the node workspace catalog.
type Workspace struct {
	ID        string         `json:"workspace_id"`
	Label     string         `json:"label"`
	Root      string         `json:"root_ref"`
	Subpath   string         `json:"subpath"`
	State     WorkspaceState `json:"state"`
	CreatedAt string         `json:"created_at"`
	LastUsed  string         `json:"last_used_at"`
}

// WorkspaceState selects active or archived workspace records.
type WorkspaceState string

const (
	WorkspaceActive   WorkspaceState = "active"
	WorkspaceArchived WorkspaceState = "archived"
)

// Folder is the workspace's folder as its root and the path inside it.
func (w Workspace) Folder() string {
	if w.Subpath == "" {
		return w.Root
	}
	return w.Root + "/" + w.Subpath
}

// WorkspacePage is one page of the catalog; Next continues it.
type WorkspacePage struct {
	Items []Workspace
	Next  string
}

// Root is a root the host admits for workspaces and its access.
type Root struct {
	Ref    string     `json:"root_ref"`
	Access RootAccess `json:"access"`
}

// RootAccess is the access level a host grants to a workspace root.
type RootAccess string

const (
	RootRead  RootAccess = "read"
	RootWrite RootAccess = "write"
)

// NewWorkspace describes a workspace to create: a folder under an admitted
// root, and whether to make that folder.
type NewWorkspace struct {
	Label           string `json:"label"`
	Root            string `json:"root_ref"`
	Subpath         string `json:"subpath,omitempty"`
	CreateDirectory bool   `json:"create_directory,omitempty"`
}

// Workspaces calls the workspace commands of one owner supervisor.
type Workspaces struct {
	client *Client
	owner  string
}

// WorkspacesOver calls the workspace commands over an existing client of the owner.
func WorkspacesOver(client *Client) *Workspaces {
	return &Workspaces{client: client, owner: client.owner}
}

func (w *Workspaces) call(ctx context.Context, operation string, input any) (json.RawMessage, error) {
	return callService(ctx, w.client, Owner{Node: w.owner, Service: WorkspaceService}, operation, input)
}

func validWorkspace(row Workspace) bool {
	labelValid := (row.Label == "" && row.Subpath == "") || (len(row.Label) > 0 && len(row.Label) <= 240)
	return durableID(row.ID) && identifier(row.Root) && validWorkspaceSubpath(row.Subpath) && labelValid &&
		utf8.ValidString(row.Label) && printable(row.Label) && (row.State == WorkspaceActive || row.State == WorkspaceArchived) &&
		canonicalTime(row.CreatedAt) && canonicalTime(row.LastUsed)
}

func validWorkspaceSubpath(value string) bool {
	if len(value) > 512 || !utf8.ValidString(value) || strings.ContainsAny(value, "\\\x00") || strings.HasPrefix(value, "/") {
		return false
	}
	if value == "" {
		return true
	}
	for _, segment := range strings.Split(value, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

func validWorkspaceCursor(value string) bool {
	if len(value) < 33 || len(value) > maxCursorBytes || !utf8.ValidString(value) {
		return false
	}
	parts := strings.Split(value, ":")
	if (len(parts) != 2 && len(parts) != 3) || !durableID(parts[0]) {
		return false
	}
	if len(parts[1])%2 != 0 || len(parts[1]) > 2*1024 || !lowerHex(parts[1]) {
		return false
	}
	if len(parts) == 3 {
		if len(parts[2]) == 0 || len(parts[2])%2 != 0 || len(parts[2]) > 2*160 || !lowerHex(parts[2]) {
			return false
		}
		root, err := hex.DecodeString(parts[2])
		if err != nil || !identifier(string(root)) {
			return false
		}
	}
	return true
}

func validNewWorkspace(workspace NewWorkspace) bool {
	return len(workspace.Label) > 0 && len(workspace.Label) <= 240 && utf8.ValidString(workspace.Label) && printable(workspace.Label) &&
		identifier(workspace.Root) && validWorkspaceSubpath(workspace.Subpath) && (!workspace.CreateDirectory || workspace.Subpath != "")
}

func (w *Workspaces) row(ctx context.Context, operation string, input any) (Workspace, error) {
	raw, err := w.call(ctx, operation, input)
	if err != nil {
		return Workspace{}, err
	}
	row, err := decodeServiceObject[Workspace](raw,
		"workspace_id", "label", "root_ref", "subpath", "state", "created_at", "last_used_at")
	if err != nil {
		return Workspace{}, err
	}
	if !validWorkspace(row) {
		return Workspace{}, ErrProtocol
	}
	return row, nil
}

func (w *Workspaces) Create(ctx context.Context, request NewWorkspace) (Workspace, error) {
	if !validNewWorkspace(request) {
		return Workspace{}, ErrProtocol
	}
	return w.row(ctx, WorkspaceCreate, request)
}

func (w *Workspaces) Archive(ctx context.Context, id string) (Workspace, error) {
	if !durableID(id) {
		return Workspace{}, ErrProtocol
	}
	return w.row(ctx, WorkspaceArchive, struct {
		ID string `json:"workspace_id"`
	}{id})
}

func (w *Workspaces) Restore(ctx context.Context, id string) (Workspace, error) {
	if !durableID(id) {
		return Workspace{}, ErrProtocol
	}
	return w.row(ctx, WorkspaceRestore, struct {
		ID string `json:"workspace_id"`
	}{id})
}

// List reads one page of the workspaces in state, after a cursor from an
// earlier page.
func (w *Workspaces) List(ctx context.Context, state WorkspaceState, after string, limit int) (WorkspacePage, error) {
	if (state != WorkspaceActive && state != WorkspaceArchived) || (after != "" && !validWorkspaceCursor(after)) || limit < 1 || limit > 100 {
		return WorkspacePage{}, ErrProtocol
	}
	input := struct {
		State string `json:"state"`
		After string `json:"after,omitempty"`
		Limit int    `json:"limit"`
	}{string(state), after, limit}
	raw, err := w.call(ctx, WorkspaceList, input)
	if err != nil {
		return WorkspacePage{}, err
	}
	value, err := decodeServiceObject[struct {
		Items json.RawMessage `json:"items"`
		Next  string          `json:"next_after,omitempty"`
	}](raw, "items")
	if err != nil {
		return WorkspacePage{}, err
	}
	items, err := list[Workspace](value.Items, limit,
		"workspace_id", "label", "root_ref", "subpath", "state", "created_at", "last_used_at")
	if err != nil {
		return WorkspacePage{}, err
	}
	if value.Next != "" && !validWorkspaceCursor(value.Next) {
		return WorkspacePage{}, ErrProtocol
	}
	for _, row := range items {
		if !validWorkspace(row) {
			return WorkspacePage{}, ErrProtocol
		}
	}
	return WorkspacePage{Items: items, Next: value.Next}, nil
}

// Roots lists the roots the host admits, in name order.
func (w *Workspaces) Roots(ctx context.Context) ([]Root, error) {
	raw, err := w.call(ctx, WorkspaceRoots, struct{}{})
	if err != nil {
		return nil, err
	}
	value, err := decodeServiceObject[struct {
		Roots json.RawMessage `json:"roots"`
	}](raw, "roots")
	if err != nil {
		return nil, err
	}
	roots, err := list[Root](value.Roots, 64, "root_ref", "access")
	if err != nil {
		return nil, err
	}
	for _, root := range roots {
		if !identifier(root.Ref) || (root.Access != RootRead && root.Access != RootWrite) {
			return nil, ErrProtocol
		}
	}
	return roots, nil
}
