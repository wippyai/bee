//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/json"
)

// The workspace commands of the owner supervisor
// (src/hive_host/supervisor/workspace_commands.lua). Each runs one operation of the
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
	ID        string `json:"workspace_id"`
	Label     string `json:"label"`
	Root      string `json:"root_ref"`
	Subpath   string `json:"subpath"`
	State     string `json:"state"`
	CreatedAt string `json:"created_at"`
	LastUsed  string `json:"last_used_at"`
}

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
	Ref    string `json:"root_ref"`
	Access string `json:"access"`
}

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

func (w *Workspaces) call(ctx context.Context, operation string, input any, into any) error {
	return callService(ctx, w.client, Owner{Node: w.owner, Service: WorkspaceService}, operation, input, into)
}

func validWorkspace(row Workspace) bool {
	return validWorkspaceID(row.ID) && identifier(row.Root) && (row.State == "active" || row.State == "archived")
}

func validWorkspaceID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, r := range id {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

func (w *Workspaces) row(ctx context.Context, operation string, input any) (Workspace, error) {
	var row Workspace
	if err := w.call(ctx, operation, input, &row); err != nil {
		return Workspace{}, err
	}
	if !validWorkspace(row) {
		return Workspace{}, ErrProtocol
	}
	return row, nil
}

func (w *Workspaces) Create(ctx context.Context, request NewWorkspace) (Workspace, error) {
	return w.row(ctx, WorkspaceCreate, request)
}

func (w *Workspaces) Archive(ctx context.Context, id string) (Workspace, error) {
	return w.row(ctx, WorkspaceArchive, struct {
		ID string `json:"workspace_id"`
	}{id})
}

func (w *Workspaces) Restore(ctx context.Context, id string) (Workspace, error) {
	return w.row(ctx, WorkspaceRestore, struct {
		ID string `json:"workspace_id"`
	}{id})
}

// List reads one page of the workspaces in state, after a cursor from an
// earlier page.
func (w *Workspaces) List(ctx context.Context, state, after string, limit int) (WorkspacePage, error) {
	var value struct {
		Items json.RawMessage `json:"items"`
		Next  string          `json:"next_after,omitempty"`
	}
	input := struct {
		State string `json:"state"`
		After string `json:"after,omitempty"`
		Limit int    `json:"limit"`
	}{state, after, limit}
	if err := w.call(ctx, WorkspaceList, input, &value); err != nil {
		return WorkspacePage{}, err
	}
	items, err := list[Workspace](value.Items)
	if err != nil {
		return WorkspacePage{}, err
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
	var value struct {
		Roots json.RawMessage `json:"roots"`
	}
	if err := w.call(ctx, WorkspaceRoots, struct{}{}, &value); err != nil {
		return nil, err
	}
	roots, err := list[Root](value.Roots)
	if err != nil {
		return nil, err
	}
	for _, root := range roots {
		if !identifier(root.Ref) || (root.Access != "read" && root.Access != "write") {
			return nil, ErrProtocol
		}
	}
	return roots, nil
}
