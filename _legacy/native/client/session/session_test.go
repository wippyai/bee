//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package session

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/physical"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/runtime/api/tty"
)

type desktopScript struct {
	plans        []hive.SessionPlan
	planRequests []hive.SessionPlanRequest
	attachErrors []error
	attached     []Selection
	created      []string
}

type detachProbe struct {
	called bool
}

func (p *detachProbe) Detach(ctx context.Context, key string, mounted hive.DesktopMount) error {
	p.called = true
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > detachTimeout {
		return errors.New("detach lost its bounded hang guard")
	}
	if ctx.Err() != nil || key != "session-detach-"+mounted.Session {
		return errors.New("detach lost its active session authority")
	}
	return nil
}

func TestDetachKeepsSessionAuthorityAndHangGuard(t *testing.T) {
	foreground, cancel := context.WithCancel(context.Background())
	cancel()
	probe := &detachProbe{}
	if err := detachMounted(foreground, probe, hive.DesktopMount{Session: "attached"}); err != nil {
		t.Fatal(err)
	}
	if !probe.called {
		t.Fatal("desktop detach was not requested")
	}
}

// stalledDetacher models an owner that never acknowledges a detach: it returns
// only when its context ends.
type stalledDetacher struct{}

func (stalledDetacher) Detach(ctx context.Context, _ string, _ hive.DesktopMount) error {
	<-ctx.Done()
	return ctx.Err()
}

// A local detach announces uncertainty instead of gating process exit on an
// owner that cannot answer, so the physical surface can retire promptly.
func TestDetachDoesNotGateLocalExitOnAnUnresponsiveOwner(t *testing.T) {
	done := make(chan error, 1)
	go func() {
		done <- detachMounted(context.Background(), stalledDetacher{}, hive.DesktopMount{Session: "attached"})
	}()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("an unacknowledged detach was reported as committed")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("local detach blocked on an unresponsive owner")
	}
}

func (s *desktopScript) Create(_ context.Context, desktop string) (string, error) {
	s.created = append(s.created, desktop)
	return desktop, nil
}

func (s *desktopScript) Plan(_ context.Context, _ string, request hive.SessionPlanRequest) (hive.SessionPlan, error) {
	s.planRequests = append(s.planRequests, request)
	if len(s.plans) == 0 {
		return nil, errors.New("unexpected desktop plan request")
	}
	plan := s.plans[0]
	s.plans = s.plans[1:]
	return plan, nil
}

func (s *desktopScript) Attach(_ context.Context, _ string, workspace, desktop string, _ hive.DesktopMode) (hive.DesktopMount, error) {
	s.attached = append(s.attached, Selection{Workspace: workspace, Desktop: desktop})
	index := len(s.attached) - 1
	if index < len(s.attachErrors) && s.attachErrors[index] != nil {
		return hive.DesktopMount{}, s.attachErrors[index]
	}
	return hive.DesktopMount{}, nil
}

func TestExplicitSelectionUsesExactOwnerPlan(t *testing.T) {
	workspace, desktop := strings.Repeat("a", 32), strings.Repeat("b", 32)
	request := &hive.SelectedSessionRequest{Workspace: workspace, Desktop: desktop, Mode: hive.Control, Desktops: []string{desktop}}
	script := &desktopScript{plans: []hive.SessionPlan{hive.AttachSessionPlan{Workspace: workspace, Desktop: desktop, Mode: hive.Control}}}
	if _, err := attachDesktop(context.Background(), script, request, nil); err != nil {
		t.Fatal(err)
	}
	if len(script.attached) != 1 || script.attached[0] != (Selection{Workspace: workspace, Desktop: desktop}) || len(script.created) != 0 {
		t.Fatalf("explicit selection changed: %+v", script)
	}
}

func TestOwnerPlanChoosesFreeDisplayOrRequestsAllocationAfterDefiniteConflicts(t *testing.T) {
	workspace := strings.Repeat("a", 32)
	first, second := strings.Repeat("b", 32), strings.Repeat("c", 32)
	controlled := &hive.Rejected{Fault: hive.Fault{Code: "DESKTOP_CONTROLLED", Message: "another controller"}}

	request := func() *hive.WorkspaceSessionRequest {
		return &hive.WorkspaceSessionRequest{Workspace: workspace, Mode: hive.Control, Desktops: []string{first, second}, Excluded: []string{}}
	}
	reuse := &desktopScript{
		plans:        []hive.SessionPlan{hive.AttachSessionPlan{Workspace: workspace, Desktop: first, Mode: hive.Control}, hive.AttachSessionPlan{Workspace: workspace, Desktop: second, Mode: hive.Control}},
		attachErrors: []error{controlled, nil},
	}
	if _, err := attachDesktop(context.Background(), reuse, request(), nil); err != nil {
		t.Fatal(err)
	}
	if len(reuse.attached) != 2 || reuse.attached[1] != (Selection{Workspace: workspace, Desktop: second}) || len(reuse.created) != 0 || len(reuse.planRequests) != 2 {
		t.Fatalf("owner's second display plan was not applied: %+v", reuse)
	}
	secondRequest, ok := reuse.planRequests[1].(*hive.WorkspaceSessionRequest)
	if !ok || len(secondRequest.Excluded) != 1 || secondRequest.Excluded[0] != first {
		t.Fatalf("controlled desktop was not reported to the owner: %#v", reuse.planRequests[1])
	}

	allocate := &desktopScript{
		plans: []hive.SessionPlan{
			hive.AttachSessionPlan{Workspace: workspace, Desktop: first, Mode: hive.Control},
			hive.AttachSessionPlan{Workspace: workspace, Desktop: second, Mode: hive.Control},
			hive.AllocateSessionPlan{Workspace: workspace},
		},
		attachErrors: []error{controlled, controlled, nil},
	}
	if _, err := attachDesktop(context.Background(), allocate, request(), nil); err != nil {
		t.Fatal(err)
	}
	if len(allocate.created) != 1 || len(allocate.attached) != 3 || len(allocate.created[0]) != 32 ||
		allocate.attached[2] != (Selection{Workspace: workspace, Desktop: allocate.created[0]}) {
		t.Fatalf("new durable display was not allocated and attached: %+v", allocate)
	}
}

func TestAutomaticDisplaySelectionNeverRetriesUnknownOrExplicitRefusal(t *testing.T) {
	workspace := strings.Repeat("a", 32)
	first := strings.Repeat("b", 32)
	unknown := errors.New("transport lost")
	request := &hive.WorkspaceSessionRequest{Workspace: workspace, Mode: hive.Control, Desktops: []string{first}, Excluded: []string{}}
	script := &desktopScript{plans: []hive.SessionPlan{hive.AttachSessionPlan{Workspace: workspace, Desktop: first, Mode: hive.Control}}, attachErrors: []error{unknown}}
	if _, err := attachDesktop(context.Background(), script, request, nil); err != unknown || len(script.attached) != 1 || len(script.created) != 0 || len(script.planRequests) != 1 {
		t.Fatalf("unknown result was retried: calls=%+v created=%+v err=%v", script.attached, script.created, err)
	}
	explicit := &desktopScript{
		plans:        []hive.SessionPlan{hive.AttachSessionPlan{Workspace: workspace, Desktop: first, Mode: hive.Control}},
		attachErrors: []error{&hive.Rejected{Fault: hive.Fault{Code: "DESKTOP_CONTROLLED"}}},
	}
	selection := &hive.SelectedSessionRequest{Workspace: workspace, Desktop: first, Mode: hive.Control, Desktops: []string{first}}
	if _, err := attachDesktop(context.Background(), explicit, selection, nil); err == nil || len(explicit.attached) != 1 || explicit.attached[0] != (Selection{Workspace: workspace, Desktop: first}) || len(explicit.created) != 0 || len(explicit.planRequests) != 1 {
		t.Fatalf("explicit selection widened: %+v err=%v", explicit, err)
	}
}

func TestMissingPhysicalInputDoesNotCreateDiscoveryState(t *testing.T) {
	directory := t.TempDir() + "/missing"
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := JoinEnrolled(context.Background(), Config{Directory: directory, EnrollmentDir: directory, Mode: hive.Control}, "client", key, nil, io.Discard); err == nil {
		t.Fatal("missing input accepted")
	}
	if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("invalid client created state", err)
	}
}

func TestCatalogWaitReadsAgainAfterStartupRefusal(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	keys := map[string]bool{}
	catalog, err := waitCatalog(ctx, func(ctx context.Context, key string, _ hive.CatalogQuery) (hive.DesktopCatalog, error) {
		if keys[key] {
			t.Fatal("reused cached request key")
		}
		keys[key] = true
		if len(keys) == 1 {
			return hive.DesktopCatalog{}, &hive.Rejected{Fault: hive.Fault{Code: "UNAVAILABLE"}}
		}
		return hive.DesktopCatalog{Workspaces: []hive.WorkspaceSummary{{ID: "ready"}}}, nil
	})
	if err != nil || len(keys) != 2 || len(catalog.Workspaces) != 1 {
		t.Fatal(catalog, err, keys)
	}
}

func TestCatalogWaitDoesNotRetryOtherFailures(t *testing.T) {
	for _, failure := range []error{&hive.Rejected{Fault: hive.Fault{Code: "FORBIDDEN"}}, hive.ErrProtocol, errors.New("transport lost")} {
		calls := 0
		_, err := waitCatalog(context.Background(), func(context.Context, string, hive.CatalogQuery) (hive.DesktopCatalog, error) {
			calls++
			return hive.DesktopCatalog{}, failure
		})
		if err != failure || calls != 1 {
			t.Fatal(calls, err)
		}
	}
}

func TestCatalogWaitCancellationStopsFurtherRequests(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	_, err := waitCatalog(ctx, func(context.Context, string, hive.CatalogQuery) (hive.DesktopCatalog, error) {
		calls++
		cancel()
		return hive.DesktopCatalog{}, &hive.Rejected{Fault: hive.Fault{Code: "UNAVAILABLE"}}
	})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal(calls, err)
	}
}

// An owner that has not published yet is a missing rendezvous: a Hive
// operation fails without creating owner state. The launch route waits for
// the publication before it joins.
func TestOperateWithoutPublicationCreatesNoOwnerState(t *testing.T) {
	directory := t.TempDir() + "/missing"
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	err = Operate(context.Background(), Config{Directory: directory, EnrollmentDir: directory}, "client", key, func(context.Context, *hive.Client, rendezvous.Descriptor) error {
		t.Error("an unpublished owner reached the operation")
		return nil
	})
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unpublished owner", err)
	}
	if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("operation created owner state", err)
	}
}

func TestForegroundCancellationCannotLeaveTransportAliveIndefinitely(t *testing.T) {
	foreground, cancel := context.WithCancel(context.Background())
	defer cancel()
	transport, closeTransport := cleanupLifetime(foreground)
	defer closeTransport()
	cancel()
	select {
	case <-transport.Done():
		t.Fatal("transport retired before detach grace")
	case <-time.After(10 * time.Millisecond):
	}
	select {
	case <-transport.Done():
	case <-time.After(4 * time.Second):
		t.Fatal("stalled cleanup left transport alive")
	}
}

func TestJoinWithoutPublicationCreatesNoOwnerState(t *testing.T) {
	directory := t.TempDir() + "/preparing-owner"
	input, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	err = JoinEnrolled(context.Background(), Config{Directory: directory, EnrollmentDir: directory, Mode: hive.Control}, "client", key, input, io.Discard)
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatal("client joined an unpublished owner", err)
	}
	if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("client created owner state", err)
	}
}

func TestPresentationFollowsTheDisplayIntoItsNewWorkspace(t *testing.T) {
	previous := hive.DesktopMount{Session: "session-1", Mount: "mount-1"}
	moved := hive.DesktopMount{Session: "session-2", Mount: "mount-2"}
	asked := 0
	current := func(context.Context) (hive.DesktopMount, error) { asked++; return moved, nil }
	reattach := func(context.Context) (hive.DesktopMount, error) {
		t.Fatal("reattached a switched session")
		return hive.DesktopMount{}, nil
	}
	if next, followed, err := followMount(context.Background(), current, reattach, previous, tty.ErrMountExpired); err != nil || !followed || next != moved {
		t.Fatalf("next=%+v followed=%v err=%v", next, followed, err)
	}
	for _, ended := range []error{nil, physical.ErrDetached, errors.New("input failed"), &physical.DeliveryError{Operation: "input", Cause: tty.ErrMountExpired}} {
		if _, followed, err := followMount(context.Background(), current, reattach, previous, ended); followed || err != nil {
			t.Fatalf("followed after %v: %v", ended, err)
		}
	}
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, followed, _ := followMount(canceled, current, reattach, previous, tty.ErrMountExpired); followed {
		t.Fatal("followed after cancellation")
	}
	if asked != 1 {
		t.Fatalf("asked the owner %d times", asked)
	}
}

func TestPresentationRenewsExpiredMountWithinSameSession(t *testing.T) {
	previous := hive.DesktopMount{Session: "session-1", Mount: "old-mount"}
	renewed := hive.DesktopMount{Session: "session-1", Mount: "new-mount"}
	current := func(context.Context) (hive.DesktopMount, error) { return previous, nil }
	reattach := func(context.Context) (hive.DesktopMount, error) { return renewed, nil }
	if next, followed, err := followMount(context.Background(), current, reattach, previous, tty.ErrMountExpired); err != nil || !followed || next != renewed {
		t.Fatalf("renewed mount not followed: next=%+v followed=%v err=%v", next, followed, err)
	}
	alreadyRenewed := func(context.Context) (hive.DesktopMount, error) { return renewed, nil }
	unexpected := func(context.Context) (hive.DesktopMount, error) {
		t.Fatal("reattached a fresh mount")
		return hive.DesktopMount{}, nil
	}
	if _, followed, err := followMount(context.Background(), alreadyRenewed, unexpected, previous, tty.ErrMountExpired); err != nil || !followed {
		t.Fatalf("owner's fresh mount not followed: %v", err)
	}
	for _, invalid := range []hive.DesktopMount{previous, {Session: "another-session", Mount: "new-mount"}} {
		reattach := func(context.Context) (hive.DesktopMount, error) { return invalid, nil }
		if _, followed, err := followMount(context.Background(), current, reattach, previous, tty.ErrMountExpired); followed || err == nil {
			t.Fatalf("accepted invalid renewal: %+v", invalid)
		}
	}
}

func TestPresentationRetainsOwnerLookupAndRenewalFailures(t *testing.T) {
	previous := hive.DesktopMount{Session: "session-1", Mount: "mount-1"}
	cause := errors.New("owner's exact refusal")
	refused := func(context.Context) (hive.DesktopMount, error) { return hive.DesktopMount{}, cause }
	current := func(context.Context) (hive.DesktopMount, error) { return previous, nil }
	for _, lookup := range []func(context.Context) (hive.DesktopMount, error){refused, current} {
		if _, followed, err := followMount(context.Background(), lookup, refused, previous, tty.ErrMountExpired); followed || !errors.Is(err, cause) {
			t.Fatalf("owner refusal lost: followed=%v err=%v", followed, err)
		}
	}
}
