//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"encoding/json"
	"errors"
	"time"

	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/runtime/api/pid"
)

const DesktopService = "bee.desktop"
const DesktopList = "bee.desktop:list"
const DesktopCreate = "bee.desktop:create"
const DesktopAttach = "bee.desktop:attach"
const DesktopDetach = "bee.desktop:detach"

type DesktopMode string

const Control DesktopMode = "control"
const Observe DesktopMode = "observe"

// DesktopSelection preserves the owner execution independently of the durable
// workspace and desktop identities. A node may own many workspaces.
type DesktopSelection struct {
	Execution string `json:"owner_execution"`
	Workspace string `json:"workspace_id"`
	Desktop   string `json:"desktop_id"`
}
type DesktopDescription struct {
	ID        string `json:"desktop_id"`
	IsDefault bool   `json:"is_default,omitempty"`
}
type WorkspaceDesktops struct {
	ID       string               `json:"workspace_id"`
	Desktops []DesktopDescription `json:"desktops"`
}
type DesktopCatalog struct {
	Execution  string              `json:"owner_execution"`
	Workspaces []WorkspaceDesktops `json:"workspaces"`
}

// DesktopMount is a validated owner reply, not a substitute for the runtime's
// recipient-bound mount check. Its lifetime may close immediately after decode.
type DesktopMount struct {
	Selection DesktopSelection
	Session   string
	Recipient pid.PID
	Mode      DesktopMode
	Mount     string
	Expires   time.Time
	lifetime  <-chan struct{}
	owner     string
}

func (m DesktopMount) Done() <-chan struct{} { return m.lifetime }

var ErrDesktopReply = errors.New("invalid or stale desktop operation reply")

func durableID(s string) bool {
	if len(s) != 32 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
func (s DesktopSelection) valid() bool {
	return durableID(s.Execution) && durableID(s.Workspace) && durableID(s.Desktop)
}
func desktopValue(reply Reply) bool {
	return reply.OK && reply.Fault == nil && len(reply.Grants) == 0 && live(reply.lifetime) && object(reply.Value)
}

// DecodeDesktopCatalog accepts only successful replies from Client.Call. Empty
// Lua arrays may be {}, but populated objects are never accepted as lists.
func DecodeDesktopCatalog(reply Reply, execution string) (DesktopCatalog, error) {
	if !durableID(execution) || !desktopValue(reply) {
		return DesktopCatalog{}, ErrDesktopReply
	}
	var wire struct {
		Execution  string          `json:"owner_execution"`
		Workspaces json.RawMessage `json:"workspaces"`
	}
	if !exactDesktopFields(reply.Value, "owner_execution", "workspaces") || strict(reply.Value, &wire) != nil || wire.Execution != execution {
		return DesktopCatalog{}, ErrDesktopReply
	}
	var workspaces []json.RawMessage
	if !desktopList(wire.Workspaces, &workspaces) || len(workspaces) > 64 {
		return DesktopCatalog{}, ErrDesktopReply
	}
	result := DesktopCatalog{Execution: execution, Workspaces: make([]WorkspaceDesktops, 0, len(workspaces))}
	seen := map[string]bool{}
	for _, rawWorkspace := range workspaces {
		var workspace struct {
			ID       string          `json:"workspace_id"`
			Desktops json.RawMessage `json:"desktops"`
		}
		if !exactDesktopFields(rawWorkspace, "workspace_id", "desktops") || strict(rawWorkspace, &workspace) != nil {
			return DesktopCatalog{}, ErrDesktopReply
		}
		var rawDesktops []json.RawMessage
		if !desktopList(workspace.Desktops, &rawDesktops) {
			return DesktopCatalog{}, ErrDesktopReply
		}
		marked := 0
		for _, rawDesktop := range rawDesktops {
			if exactDesktopFields(rawDesktop, "desktop_id", "is_default") {
				marked++
			} else if !exactDesktopFields(rawDesktop, "desktop_id") {
				return DesktopCatalog{}, ErrDesktopReply
			}
		}
		var desktops []DesktopDescription
		if !durableID(workspace.ID) || seen[workspace.ID] || !desktopList(workspace.Desktops, &desktops) || len(desktops) > 64 {
			return DesktopCatalog{}, ErrDesktopReply
		}
		if marked != 0 && marked != len(desktops) {
			return DesktopCatalog{}, ErrDesktopReply
		}
		seen[workspace.ID] = true
		defaults := 0
		ids := map[string]bool{}
		for _, desktop := range desktops {
			if !durableID(desktop.ID) || ids[desktop.ID] {
				return DesktopCatalog{}, ErrDesktopReply
			}
			ids[desktop.ID] = true
			if desktop.IsDefault {
				defaults++
			}
		}
		if marked > 0 && defaults != 1 {
			return DesktopCatalog{}, ErrDesktopReply
		}
		result.Workspaces = append(result.Workspaces, WorkspaceDesktops{ID: workspace.ID, Desktops: desktops})
	}
	if !live(reply.lifetime) {
		return DesktopCatalog{}, ErrDesktopReply
	}
	return result, nil
}

// DecodeDesktopCreated validates allocation independently of attachment.
// Allocation retains an identity but grants no viewport or controller rights.
func DecodeDesktopCreated(reply Reply, selected DesktopSelection) error {
	if !selected.valid() || !desktopValue(reply) {
		return ErrDesktopReply
	}
	var wire DesktopSelection
	if !exactDesktopFields(reply.Value, "owner_execution", "workspace_id", "desktop_id") ||
		strict(reply.Value, &wire) != nil || wire != selected || !live(reply.lifetime) {
		return ErrDesktopReply
	}
	return nil
}
func desktopList(raw json.RawMessage, into any) bool {
	if !present(raw) {
		return false
	}
	if object(raw) {
		var members map[string]json.RawMessage
		return json.Unmarshal(raw, &members) == nil && len(members) == 0
	}
	return strict(raw, into) == nil
}

func DecodeDesktopMount(reply Reply, selected DesktopSelection, recipient pid.PID, mode DesktopMode, now time.Time) (DesktopMount, error) {
	if !selected.valid() || recipient.Node == "" || recipient.Host != mesh.ActorHost || recipient.UniqID == "" ||
		(mode != Control && mode != Observe) || now.IsZero() || !desktopValue(reply) {
		return DesktopMount{}, ErrDesktopReply
	}
	var wire struct {
		DesktopSelection
		Session   string      `json:"session_id"`
		Recipient string      `json:"recipient"`
		Mode      DesktopMode `json:"mode"`
		Mount     string      `json:"mount_ref"`
		Expires   string      `json:"expires_at"`
	}
	if !exactDesktopFields(reply.Value, "owner_execution", "workspace_id", "desktop_id", "session_id", "recipient", "mode", "mount_ref", "expires_at") || strict(reply.Value, &wire) != nil || wire.DesktopSelection != selected || !identifier(wire.Session) ||
		wire.Recipient != recipient.String() || wire.Mode != mode || !boundedMount(wire.Mount) || !canonicalTime(wire.Expires) {
		return DesktopMount{}, ErrDesktopReply
	}
	expiry, err := time.Parse("2006-01-02T15:04:05.000Z", wire.Expires)
	if err != nil || !now.Before(expiry) || !live(reply.lifetime) {
		return DesktopMount{}, ErrDesktopReply
	}
	return DesktopMount{Selection: selected, Session: wire.Session, Recipient: recipient, Mode: mode, Mount: wire.Mount, Expires: expiry, lifetime: reply.lifetime}, nil
}
func boundedMount(s string) bool {
	if s == "" || len(s) > 4096 {
		return false
	}
	for _, c := range s {
		if c < 32 || c == 127 {
			return false
		}
	}
	return true
}

func DecodeDesktopDetached(reply Reply, selected DesktopSelection) error {
	if !selected.valid() || !desktopValue(reply) {
		return ErrDesktopReply
	}
	var wire struct {
		DesktopSelection
		Detached *bool `json:"detached"`
	}
	if !exactDesktopFields(reply.Value, "owner_execution", "workspace_id", "desktop_id", "detached") || strict(reply.Value, &wire) != nil || wire.DesktopSelection != selected || wire.Detached == nil || !*wire.Detached {
		return ErrDesktopReply
	}
	if !live(reply.lifetime) {
		return ErrDesktopReply
	}
	return nil
}

// Match Lua's exact field spelling; encoding/json otherwise accepts case aliases.
func exactDesktopFields(raw json.RawMessage, names ...string) bool {
	if !object(raw) {
		return false
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || len(fields) != len(names) {
		return false
	}
	for _, name := range names {
		if !present(fields[name]) {
			return false
		}
	}
	return true
}
