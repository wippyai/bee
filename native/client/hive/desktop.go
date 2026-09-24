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

// DesktopCurrent reads the client's current session. After its display was
// switched to another workspace, the session and mount are new.
const DesktopCurrent = "bee.desktop:current"

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

// DesktopDescription is one of the node's durable display identities. Displays
// belong to the node; each shows whichever workspace it attaches to.
type DesktopDescription struct {
	ID        string `json:"desktop_id"`
	IsDefault bool   `json:"is_default"`
}

// WorkspaceSummary is one row of the node's workspace catalog as the owner
// lists it. Served says whether the owner holds a desktop supervisor for it now.
type WorkspaceSummary struct {
	ID     string `json:"workspace_id"`
	Label  string `json:"label"`
	Served bool   `json:"served"`
}

// DesktopCatalog is one page of the node's workspaces and the node's displays.
// Next continues the page; Default names the workspace the owner composes as
// its folder workspace, if any.
type DesktopCatalog struct {
	Execution  string
	Desktops   []DesktopDescription
	Workspaces []WorkspaceSummary
	Next       string
	Default    string
}

// CatalogQuery selects one catalog page: a label prefix and a cursor.
type CatalogQuery struct {
	Label string
	After string
}

// MaxCatalogPage bounds the workspaces one page carries.
const MaxCatalogPage = 50
const maxLabelBytes = 240
const maxCursorBytes = 2200
const maxDesktops = 33

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
	var fields map[string]json.RawMessage
	if json.Unmarshal(reply.Value, &fields) != nil {
		return DesktopCatalog{}, ErrDesktopReply
	}
	names := []string{"owner_execution", "desktops", "workspaces"}
	for _, optional := range []string{"next_after", "default_workspace"} {
		if _, ok := fields[optional]; ok {
			names = append(names, optional)
		}
	}
	var wire struct {
		Execution  string          `json:"owner_execution"`
		Desktops   json.RawMessage `json:"desktops"`
		Workspaces json.RawMessage `json:"workspaces"`
		Next       *string         `json:"next_after"`
		Default    *string         `json:"default_workspace"`
	}
	if !exactDesktopFields(reply.Value, names...) || strict(reply.Value, &wire) != nil || wire.Execution != execution {
		return DesktopCatalog{}, ErrDesktopReply
	}
	result := DesktopCatalog{Execution: execution}
	if wire.Next != nil {
		if *wire.Next == "" || len(*wire.Next) > maxCursorBytes || !printable(*wire.Next) {
			return DesktopCatalog{}, ErrDesktopReply
		}
		result.Next = *wire.Next
	}
	if wire.Default != nil {
		if !durableID(*wire.Default) {
			return DesktopCatalog{}, ErrDesktopReply
		}
		result.Default = *wire.Default
	}
	var rawDesktops []json.RawMessage
	if !desktopList(wire.Desktops, &rawDesktops) || len(rawDesktops) == 0 || len(rawDesktops) > maxDesktops {
		return DesktopCatalog{}, ErrDesktopReply
	}
	ids := map[string]bool{}
	for index, raw := range rawDesktops {
		var desktop DesktopDescription
		if !exactDesktopFields(raw, "desktop_id", "is_default") || strict(raw, &desktop) != nil ||
			!durableID(desktop.ID) || ids[desktop.ID] || desktop.IsDefault != (index == 0) {
			return DesktopCatalog{}, ErrDesktopReply
		}
		ids[desktop.ID] = true
		result.Desktops = append(result.Desktops, desktop)
	}
	var rawWorkspaces []json.RawMessage
	if !desktopList(wire.Workspaces, &rawWorkspaces) || len(rawWorkspaces) > MaxCatalogPage {
		return DesktopCatalog{}, ErrDesktopReply
	}
	seen := map[string]bool{}
	for _, raw := range rawWorkspaces {
		var workspace WorkspaceSummary
		if !exactDesktopFields(raw, "workspace_id", "label", "served") || strict(raw, &workspace) != nil ||
			!durableID(workspace.ID) || seen[workspace.ID] || len(workspace.Label) > maxLabelBytes || !printable(workspace.Label) {
			return DesktopCatalog{}, ErrDesktopReply
		}
		seen[workspace.ID] = true
		result.Workspaces = append(result.Workspaces, workspace)
	}
	if !live(reply.lifetime) {
		return DesktopCatalog{}, ErrDesktopReply
	}
	return result, nil
}

// printable refuses control characters in owner text a terminal will show.
func printable(s string) bool {
	for _, c := range s {
		if c < 32 || c == 127 {
			return false
		}
	}
	return true
}

// DecodeDesktopCreated validates allocation independently of attachment.
// Allocation retains a node display identity but grants no viewport or
// controller rights.
func DecodeDesktopCreated(reply Reply, execution, desktop string) error {
	if !durableID(execution) || !durableID(desktop) || !desktopValue(reply) {
		return ErrDesktopReply
	}
	var wire struct {
		Execution string `json:"owner_execution"`
		Desktop   string `json:"desktop_id"`
	}
	if !exactDesktopFields(reply.Value, "owner_execution", "desktop_id") ||
		strict(reply.Value, &wire) != nil || wire.Execution != execution || wire.Desktop != desktop || !live(reply.lifetime) {
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

// DecodeDesktopCurrent validates the client's current session on the same
// display under the same execution. Only the workspace may differ from the
// session the client presented before.
func DecodeDesktopCurrent(reply Reply, execution, desktop string, recipient pid.PID, mode DesktopMode, now time.Time) (DesktopMount, error) {
	if !desktopValue(reply) {
		return DesktopMount{}, ErrDesktopReply
	}
	var fields map[string]json.RawMessage
	var workspace string
	if json.Unmarshal(reply.Value, &fields) != nil || json.Unmarshal(fields["workspace_id"], &workspace) != nil || !durableID(workspace) {
		return DesktopMount{}, ErrDesktopReply
	}
	return DecodeDesktopMount(reply, DesktopSelection{Execution: execution, Workspace: workspace, Desktop: desktop}, recipient, mode, now)
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
