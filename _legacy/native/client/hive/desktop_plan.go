//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/wippyai/bee/native/internal/jsonwire"
)

// SessionPlanRequest is one request to the owner's session policy.
type SessionPlanRequest interface {
	sessionPlanRequest() (sessionPlanWire, error)
}

type sessionPlanWire struct {
	mode      DesktopMode
	workspace string
	desktop   string
	desktops  []string
	excluded  []string
	kind      string
	value     json.RawMessage
}

// AutomaticSessionRequest lets the owner choose its default workspace and a display.
type AutomaticSessionRequest struct {
	Mode     DesktopMode
	Desktops []string
	Excluded []string
}

func (request *AutomaticSessionRequest) sessionPlanRequest() (sessionPlanWire, error) {
	if request == nil || !validPlanCandidates(request.Desktops, request.Excluded) || (request.Mode != Control && request.Mode != Observe) {
		return sessionPlanWire{}, errors.New("invalid automatic desktop session plan")
	}
	value, err := json.Marshal(struct {
		Kind     string      `json:"kind"`
		Mode     DesktopMode `json:"mode"`
		Desktops []string    `json:"desktops"`
		Excluded []string    `json:"excluded"`
	}{"automatic", request.Mode, request.Desktops, request.Excluded})
	return sessionPlanWire{mode: request.Mode, desktops: append([]string(nil), request.Desktops...),
		excluded: append([]string(nil), request.Excluded...), kind: "automatic", value: value}, err
}

// WorkspaceSessionRequest asks the owner to choose a display for one workspace.
type WorkspaceSessionRequest struct {
	Workspace string
	Mode      DesktopMode
	Desktops  []string
	Excluded  []string
}

func (request *WorkspaceSessionRequest) sessionPlanRequest() (sessionPlanWire, error) {
	if request == nil || !durableID(request.Workspace) || !validPlanCandidates(request.Desktops, request.Excluded) ||
		(request.Mode != Control && request.Mode != Observe) {
		return sessionPlanWire{}, errors.New("invalid workspace desktop session plan")
	}
	value, err := json.Marshal(struct {
		Kind      string      `json:"kind"`
		Mode      DesktopMode `json:"mode"`
		Workspace string      `json:"workspace_id"`
		Desktops  []string    `json:"desktops"`
		Excluded  []string    `json:"excluded"`
	}{"workspace", request.Mode, request.Workspace, request.Desktops, request.Excluded})
	return sessionPlanWire{mode: request.Mode, workspace: request.Workspace, desktops: append([]string(nil), request.Desktops...),
		excluded: append([]string(nil), request.Excluded...), kind: "workspace", value: value}, err
}

// SelectedSessionRequest preserves an exact workspace and display selection.
type SelectedSessionRequest struct {
	Workspace string
	Desktop   string
	Mode      DesktopMode
	Desktops  []string
}

func (request *SelectedSessionRequest) sessionPlanRequest() (sessionPlanWire, error) {
	if request == nil || !durableID(request.Workspace) || !durableID(request.Desktop) ||
		(request.Mode != Control && request.Mode != Observe) || !validPlanCandidates(request.Desktops, []string{}) ||
		!containsDesktop(request.Desktops, request.Desktop) {
		return sessionPlanWire{}, errors.New("invalid selected desktop session plan")
	}
	value, err := json.Marshal(struct {
		Kind      string      `json:"kind"`
		Mode      DesktopMode `json:"mode"`
		Workspace string      `json:"workspace_id"`
		Desktop   string      `json:"desktop_id"`
		Desktops  []string    `json:"desktops"`
	}{"selection", request.Mode, request.Workspace, request.Desktop, request.Desktops})
	return sessionPlanWire{mode: request.Mode, workspace: request.Workspace, desktop: request.Desktop,
		desktops: append([]string(nil), request.Desktops...), kind: "selection", value: value}, err
}

// SessionPlan is a decision from the owner contract.
type SessionPlan interface{ isSessionPlan() }

// ChooseWorkspacePlan asks the native client to present its workspace picker.
type ChooseWorkspacePlan struct{}

func (ChooseWorkspacePlan) isSessionPlan() {}

// AttachSessionPlan names the workspace and display the owner selected.
type AttachSessionPlan struct {
	Workspace string
	Desktop   string
	Mode      DesktopMode
}

func (AttachSessionPlan) isSessionPlan() {}

// AllocateSessionPlan asks the native client to create a display for the workspace.
type AllocateSessionPlan struct{ Workspace string }

func (AllocateSessionPlan) isSessionPlan() {}

func validPlanCandidates(desktops, excluded []string) bool {
	if len(desktops) == 0 || len(desktops) > maxDesktops || excluded == nil {
		return false
	}
	seen := make(map[string]bool, len(desktops))
	for _, desktop := range desktops {
		if !durableID(desktop) || seen[desktop] {
			return false
		}
		seen[desktop] = true
	}
	failed := make(map[string]bool, len(excluded))
	for _, desktop := range excluded {
		if !seen[desktop] || failed[desktop] {
			return false
		}
		failed[desktop] = true
	}
	return true
}

func containsDesktop(desktops []string, selected string) bool {
	for _, desktop := range desktops {
		if desktop == selected {
			return true
		}
	}
	return false
}

// Plan asks the owner to choose a workspace and desktop action. It makes no
// attachment or allocation itself; the selected operation remains separately
// admitted and correlated.
func (d *Desktop) Plan(ctx context.Context, key string, request SessionPlanRequest) (SessionPlan, error) {
	if d == nil || request == nil {
		return nil, errors.New("desktop client unavailable")
	}
	wire, err := request.sessionPlanRequest()
	if err != nil {
		return nil, err
	}
	reply, err := d.call(ctx, DesktopPlan, key, struct {
		Execution string          `json:"owner_execution"`
		Request   json.RawMessage `json:"request"`
	}{d.execution, wire.value})
	if err != nil {
		return nil, err
	}
	if !desktopValue(reply) {
		return nil, ErrDesktopReply
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(reply.Value, &fields) != nil {
		return nil, ErrDesktopReply
	}
	var kind string
	if json.Unmarshal(fields["kind"], &kind) != nil {
		return nil, ErrDesktopReply
	}
	switch kind {
	case "choose_workspace":
		if !exactDesktopFields(reply.Value, "kind") || wire.kind != "automatic" {
			return nil, ErrDesktopReply
		}
		return ChooseWorkspacePlan{}, nil
	case "attach":
		plan, err := jsonwire.DecodeObject[struct {
			Kind      string      `json:"kind"`
			Workspace string      `json:"workspace_id"`
			Desktop   string      `json:"desktop_id"`
			Mode      DesktopMode `json:"mode"`
		}](reply.Value, maxBytes, "kind", "workspace_id", "desktop_id", "mode")
		if err != nil || plan.Kind != kind || !durableID(plan.Workspace) || !containsDesktop(wire.desktops, plan.Desktop) ||
			containsDesktop(wire.excluded, plan.Desktop) || (plan.Mode != Control && plan.Mode != Observe) || plan.Mode != wire.mode ||
			(wire.workspace != "" && plan.Workspace != wire.workspace) || (wire.desktop != "" && plan.Desktop != wire.desktop) {
			return nil, ErrDesktopReply
		}
		return AttachSessionPlan{Workspace: plan.Workspace, Desktop: plan.Desktop, Mode: plan.Mode}, nil
	case "allocate":
		plan, err := jsonwire.DecodeObject[struct {
			Kind      string `json:"kind"`
			Workspace string `json:"workspace_id"`
		}](reply.Value, maxBytes, "kind", "workspace_id")
		if err != nil || plan.Kind != kind || wire.kind == "selection" || wire.mode != Control || !durableID(plan.Workspace) ||
			(wire.workspace != "" && plan.Workspace != wire.workspace) {
			return nil, ErrDesktopReply
		}
		return AllocateSessionPlan{Workspace: plan.Workspace}, nil
	default:
		return nil, ErrDesktopReply
	}
}
