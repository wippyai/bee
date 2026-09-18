//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package session

import (
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/hive/rendezvous"
)

type desktopScript struct {
	attachErrors []error
	attached     []Selection
	created      []Selection
}

func (s *desktopScript) Create(_ context.Context, workspace, desktop string) (hive.DesktopSelection, error) {
	s.created = append(s.created, Selection{Workspace: workspace, Desktop: desktop})
	return hive.DesktopSelection{Execution: strings.Repeat("e", 32), Workspace: workspace, Desktop: desktop}, nil
}

func (s *desktopScript) Attach(_ context.Context, _ string, workspace, desktop string, _ hive.DesktopMode) (hive.DesktopMount, error) {
	s.attached = append(s.attached, Selection{Workspace: workspace, Desktop: desktop})
	index := len(s.attached) - 1
	if index < len(s.attachErrors) && s.attachErrors[index] != nil {
		return hive.DesktopMount{}, s.attachErrors[index]
	}
	return hive.DesktopMount{}, nil
}

func TestDesktopSelectionNeverUsesDiscoveryOrder(t *testing.T) {
	catalog := hive.DesktopCatalog{Workspaces: []hive.WorkspaceDesktops{
		{ID: "workspace-a", Desktops: []hive.DesktopDescription{{ID: "desktop-a"}}},
		{ID: "workspace-b", Desktops: []hive.DesktopDescription{{ID: "desktop-b"}}},
	}}
	if _, err := selectDesktop(catalog, Selection{}); err == nil {
		t.Fatal("ambiguous catalog silently selected")
	}
	want := Selection{Workspace: "workspace-b", Desktop: "desktop-b"}
	if got, err := selectDesktop(catalog, want); err != nil || got != want {
		t.Fatalf("selection=%v error=%v", got, err)
	}
	for _, selection := range []Selection{{Workspace: "workspace-a"}, {Desktop: "desktop-a"}, {Workspace: "workspace-a", Desktop: "desktop-b"}} {
		if _, err := selectDesktop(catalog, selection); err == nil {
			t.Fatalf("invalid selection accepted: %v", selection)
		}
	}
	catalog.Workspaces = catalog.Workspaces[:1]
	if got, err := selectDesktop(catalog, Selection{}); err != nil || got.Workspace != "workspace-a" || got.Desktop != "desktop-a" {
		t.Fatal(got, err)
	}
	if _, err := selectDesktop(hive.DesktopCatalog{}, Selection{}); err == nil {
		t.Fatal("empty catalog accepted")
	}
}

func TestOrdinaryControlReusesFreeDisplayOrAllocatesAfterDefiniteConflicts(t *testing.T) {
	workspace := strings.Repeat("a", 32)
	first, second := strings.Repeat("b", 32), strings.Repeat("c", 32)
	catalog := hive.DesktopCatalog{Workspaces: []hive.WorkspaceDesktops{{ID: workspace, Desktops: []hive.DesktopDescription{{ID: first}, {ID: second}}}}}
	controlled := &hive.Rejected{Fault: hive.Fault{Code: "DESKTOP_CONTROLLED", Message: "another controller"}}

	reuse := &desktopScript{attachErrors: []error{controlled, nil}}
	if _, err := attachDesktop(context.Background(), reuse, catalog, Selection{}, hive.Control); err != nil {
		t.Fatal(err)
	}
	if len(reuse.attached) != 2 || reuse.attached[1] != (Selection{Workspace: workspace, Desktop: second}) || len(reuse.created) != 0 {
		t.Fatalf("free display was not reused: %+v", reuse)
	}

	allocate := &desktopScript{attachErrors: []error{controlled, controlled, nil}}
	if _, err := attachDesktop(context.Background(), allocate, catalog, Selection{}, hive.Control); err != nil {
		t.Fatal(err)
	}
	if len(allocate.created) != 1 || len(allocate.attached) != 3 || allocate.created[0].Workspace != workspace ||
		len(allocate.created[0].Desktop) != 32 || allocate.attached[2] != allocate.created[0] {
		t.Fatalf("new durable display was not allocated and attached: %+v", allocate)
	}
}

func TestAutomaticDisplaySelectionNeverRetriesUnknownOrExplicitRefusal(t *testing.T) {
	workspace := strings.Repeat("a", 32)
	first, second := strings.Repeat("b", 32), strings.Repeat("c", 32)
	catalog := hive.DesktopCatalog{Workspaces: []hive.WorkspaceDesktops{{ID: workspace, Desktops: []hive.DesktopDescription{{ID: first}, {ID: second}}}}}
	unknown := errors.New("transport lost")
	script := &desktopScript{attachErrors: []error{unknown}}
	if _, err := attachDesktop(context.Background(), script, catalog, Selection{}, hive.Control); err != unknown || len(script.attached) != 1 || len(script.created) != 0 {
		t.Fatalf("unknown result was retried: calls=%+v created=%+v err=%v", script.attached, script.created, err)
	}
	explicit := &desktopScript{attachErrors: []error{&hive.Rejected{Fault: hive.Fault{Code: "DESKTOP_CONTROLLED"}}}}
	selected := Selection{Workspace: workspace, Desktop: second}
	if _, err := attachDesktop(context.Background(), explicit, catalog, selected, hive.Control); err == nil || len(explicit.attached) != 1 || explicit.attached[0] != selected || len(explicit.created) != 0 {
		t.Fatalf("explicit selection widened: %+v err=%v", explicit, err)
	}
}

func TestMissingPhysicalInputDoesNotCreateDiscoveryState(t *testing.T) {
	directory := t.TempDir() + "/missing"
	if err := Join(context.Background(), Config{Directory: directory, Mode: hive.Control}, nil, io.Discard); err == nil {
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
	catalog, err := waitCatalog(ctx, func(ctx context.Context, key string) (hive.DesktopCatalog, error) {
		if keys[key] {
			t.Fatal("reused cached request key")
		}
		keys[key] = true
		if len(keys) == 1 {
			return hive.DesktopCatalog{}, &hive.Rejected{Fault: hive.Fault{Code: "UNAVAILABLE"}}
		}
		return hive.DesktopCatalog{Workspaces: []hive.WorkspaceDesktops{{ID: "ready"}}}, nil
	})
	if err != nil || len(keys) != 2 || len(catalog.Workspaces) != 1 {
		t.Fatal(catalog, err, keys)
	}
}

func TestCatalogWaitDoesNotRetryOtherFailures(t *testing.T) {
	for _, failure := range []error{&hive.Rejected{Fault: hive.Fault{Code: "FORBIDDEN"}}, hive.ErrProtocol, errors.New("transport lost")} {
		calls := 0
		_, err := waitCatalog(context.Background(), func(context.Context, string) (hive.DesktopCatalog, error) {
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
	_, err := waitCatalog(ctx, func(context.Context, string) (hive.DesktopCatalog, error) {
		calls++
		cancel()
		return hive.DesktopCatalog{}, &hive.Rejected{Fault: hive.Fault{Code: "UNAVAILABLE"}}
	})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatal(calls, err)
	}
}

func TestProbeWaitsForPublicationWithoutCreatingOwnerState(t *testing.T) {
	directory := t.TempDir() + "/missing"
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := Probe(ctx, directory); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("missing owner did not wait", err)
	}
	if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("probe created owner state", err)
	}
}

func TestPublicationWaitDoesNotHideCorruptionOrPermissionFailure(t *testing.T) {
	for _, failure := range []error{rendezvous.ErrDescriptor, os.ErrPermission} {
		calls := 0
		err := awaitPublication(context.Background(), func(context.Context) (rendezvous.Descriptor, error) { calls++; return rendezvous.Descriptor{}, failure })
		if err != failure || calls != 1 {
			t.Fatal(err, calls)
		}
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

func TestJoinWaitsForOwnerPublicationWithoutCreatingState(t *testing.T) {
	directory := t.TempDir() + "/preparing-owner"
	input, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	err = Join(ctx, Config{Directory: directory, Mode: hive.Control}, input, io.Discard)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("client failed before owner could publish", err)
	}
	if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("client created owner state", err)
	}
}
