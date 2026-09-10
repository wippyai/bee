//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package session

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
)

type attemptedDesktop struct {
	workspace, desktop, key string
	mode                    hive.DesktopMode
}
type admissionProbe struct {
	attempts     []attemptedDesktop
	creates      []Selection
	refuse       map[string]error
	createError  error
	createErrors []error
}

func (p *admissionProbe) Attach(ctx context.Context, key, workspace, desktop string, mode hive.DesktopMode) (hive.DesktopMount, error) {
	if err := ctx.Err(); err != nil {
		return hive.DesktopMount{}, err
	}
	p.attempts = append(p.attempts, attemptedDesktop{workspace, desktop, key, mode})
	return hive.DesktopMount{Selection: hive.DesktopSelection{Workspace: workspace, Desktop: desktop}}, p.refuse[desktop]
}
func (p *admissionProbe) Create(ctx context.Context, workspace, desktop string) (hive.DesktopSelection, error) {
	p.creates = append(p.creates, Selection{Workspace: workspace, Desktop: desktop})
	err := p.createError
	if len(p.creates) <= len(p.createErrors) {
		err = p.createErrors[len(p.creates)-1]
	}
	return hive.DesktopSelection{Workspace: workspace, Desktop: desktop}, err
}
func controlled() error {
	return &hive.Rejected{Fault: hive.Fault{Code: "DESKTOP_CONTROLLED", Message: "Desktop already has a controller"}}
}
func admissionCatalog() hive.DesktopCatalog {
	return hive.DesktopCatalog{Workspaces: []hive.WorkspaceDesktops{{ID: "workspace", Desktops: []hive.DesktopDescription{
		{ID: "z"}, {ID: "main", IsDefault: true}, {ID: "a"},
	}}}}
}
func TestAutomaticAdmissionReusesOneDesktopWithoutTakingAnotherController(t *testing.T) {
	p := &admissionProbe{refuse: map[string]error{"main": controlled(), "a": controlled()}}
	mounted, err := attachDesktop(context.Background(), p, admissionCatalog(), Selection{}, hive.Control)
	if err != nil || mounted.Selection.Desktop != "z" || len(p.creates) != 0 || len(p.attempts) != 3 {
		t.Fatal(mounted, err, p)
	}
	for i, want := range []string{"main", "a", "z"} {
		got := p.attempts[i]
		if got.desktop != want || got.workspace != "workspace" || got.mode != hive.Control {
			t.Fatal(p.attempts)
		}
		for j := 0; j < i; j++ {
			if got.key == p.attempts[j].key {
				t.Fatal("reused mutation key")
			}
		}
	}
}
func TestAutomaticAdmissionAllocatesOnceOnlyAfterKnownControllerRefusals(t *testing.T) {
	p := &admissionProbe{refuse: map[string]error{"main": controlled(), "a": controlled(), "z": controlled()}}
	mounted, err := attachDesktop(context.Background(), p, admissionCatalog(), Selection{}, hive.Control)
	if err != nil || len(p.creates) != 1 || len(p.attempts) != 4 {
		t.Fatal(mounted, err, p)
	}
	created := p.creates[0]
	if created.Workspace != "workspace" || len(created.Desktop) != 32 || strings.Trim(created.Desktop, "0123456789abcdef") != "" || mounted.Selection.Desktop != created.Desktop {
		t.Fatal(created, mounted)
	}
}
func TestAdmissionNeverRedirectsExplicitSelectionOrObserver(t *testing.T) {
	for _, mode := range []hive.DesktopMode{hive.Control, hive.Observe} {
		selection := Selection{Workspace: "workspace", Desktop: "main"}
		if mode == hive.Observe {
			selection = Selection{}
		}
		p := &admissionProbe{refuse: map[string]error{"main": controlled()}}
		_, err := attachDesktop(context.Background(), p, admissionCatalog(), selection, mode)
		if err == nil || len(p.attempts) != 1 || len(p.creates) != 0 {
			t.Fatal(mode, p, err)
		}
	}
}
func TestAdmissionNeverFallsBackAfterUncertaintyOrUnrelatedRefusal(t *testing.T) {
	for _, failure := range []error{
		&hive.UnknownOutcome{Operation: hive.DesktopAttach, Key: "original", Cause: controlled()},
		&hive.Rejected{Fault: hive.Fault{Code: "BUSY", Message: "Desktop activation or shutdown is pending"}},
		&hive.Rejected{Fault: hive.Fault{Code: "UNAVAILABLE", Message: "Desktop already has a controller"}},
		&hive.Rejected{Fault: hive.Fault{Code: "DENIED", Message: "host denied"}},
		context.DeadlineExceeded,
	} {
		p := &admissionProbe{refuse: map[string]error{"main": failure}}
		_, err := attachDesktop(context.Background(), p, admissionCatalog(), Selection{}, hive.Control)
		if err != failure || len(p.attempts) != 1 || len(p.creates) != 0 {
			t.Fatal(err, p)
		}
	}
}
func TestUnknownAllocationKeepsItsIdentityAndDoesNotAttachOrCreateAgain(t *testing.T) {
	uncertain := &hive.UnknownOutcome{Operation: hive.DesktopCreate, Cause: context.DeadlineExceeded}
	p := &admissionProbe{refuse: map[string]error{"main": controlled(), "a": controlled(), "z": controlled()}, createError: uncertain}
	_, err := attachDesktop(context.Background(), p, admissionCatalog(), Selection{}, hive.Control)
	if !errors.Is(err, uncertain) || len(p.creates) != 1 || len(p.attempts) != 3 || !strings.Contains(err.Error(), p.creates[0].Desktop) {
		t.Fatal(err, p)
	}
}

func TestAllocationContentionReusesIdentityButCapacityStops(t *testing.T) {
	busy := &hive.Rejected{Fault: hive.Fault{Code: "BUSY", Message: "Desktop catalog request already pending"}}
	p := &admissionProbe{createErrors: []error{busy, nil}}
	if err := createDesktop(context.Background(), p, "workspace", "retained"); err != nil || len(p.creates) != 2 || p.creates[0] != p.creates[1] {
		t.Fatal(err, p)
	}
	capacity := &hive.Rejected{Fault: hive.Fault{Code: "LIMIT_EXCEEDED", Message: "Desktop capacity reached"}}
	p = &admissionProbe{createError: capacity}
	if err := createDesktop(context.Background(), p, "workspace", "retained"); err != capacity || len(p.creates) != 1 {
		t.Fatal(err, p)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	p = &admissionProbe{createError: busy}
	if err := createDesktop(ctx, p, "workspace", "retained"); !errors.Is(err, context.Canceled) || len(p.creates) != 0 {
		t.Fatal(err, p)
	}
}
