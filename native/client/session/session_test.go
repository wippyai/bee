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
	"github.com/wippyai/bee/native/hive/rendezvous"
)

type desktopScript struct {
	attachErrors []error
	attached     []Selection
	created      []string
}

func (s *desktopScript) Create(_ context.Context, desktop string) (string, error) {
	s.created = append(s.created, desktop)
	return desktop, nil
}

func (s *desktopScript) Attach(_ context.Context, _ string, workspace, desktop string, _ hive.DesktopMode) (hive.DesktopMount, error) {
	s.attached = append(s.attached, Selection{Workspace: workspace, Desktop: desktop})
	index := len(s.attached) - 1
	if index < len(s.attachErrors) && s.attachErrors[index] != nil {
		return hive.DesktopMount{}, s.attachErrors[index]
	}
	return hive.DesktopMount{}, nil
}

func TestExplicitSelectionNamesANodeDisplayInTheNamedWorkspace(t *testing.T) {
	catalog := hive.DesktopCatalog{Desktops: []hive.DesktopDescription{{ID: "desktop-a", IsDefault: true}, {ID: "desktop-b"}}}
	want := Selection{Workspace: "workspace-b", Desktop: "desktop-b"}
	if got, err := selectDesktop(catalog, want); err != nil || got != want {
		t.Fatalf("selection=%v error=%v", got, err)
	}
	for _, selection := range []Selection{{Workspace: "workspace-a"}, {Desktop: "desktop-a"}, {Workspace: "workspace-a", Desktop: "desktop-c"}} {
		if _, err := selectDesktop(catalog, selection); err == nil {
			t.Fatalf("invalid selection accepted: %v", selection)
		}
	}
	script := &desktopScript{}
	if _, err := attachDesktop(context.Background(), script, catalog, "", Selection{}, hive.Control); err == nil || len(script.attached) != 0 {
		t.Fatal("attached without a workspace")
	}
}

func TestOrdinaryControlReusesFreeDisplayOrAllocatesAfterDefiniteConflicts(t *testing.T) {
	workspace := strings.Repeat("a", 32)
	first, second := strings.Repeat("b", 32), strings.Repeat("c", 32)
	catalog := hive.DesktopCatalog{Desktops: []hive.DesktopDescription{{ID: first, IsDefault: true}, {ID: second}}}
	controlled := &hive.Rejected{Fault: hive.Fault{Code: "DESKTOP_CONTROLLED", Message: "another controller"}}

	reuse := &desktopScript{attachErrors: []error{controlled, nil}}
	if _, err := attachDesktop(context.Background(), reuse, catalog, workspace, Selection{}, hive.Control); err != nil {
		t.Fatal(err)
	}
	if len(reuse.attached) != 2 || reuse.attached[1] != (Selection{Workspace: workspace, Desktop: second}) || len(reuse.created) != 0 {
		t.Fatalf("free display was not reused: %+v", reuse)
	}

	allocate := &desktopScript{attachErrors: []error{controlled, controlled, nil}}
	if _, err := attachDesktop(context.Background(), allocate, catalog, workspace, Selection{}, hive.Control); err != nil {
		t.Fatal(err)
	}
	if len(allocate.created) != 1 || len(allocate.attached) != 3 || len(allocate.created[0]) != 32 ||
		allocate.attached[2] != (Selection{Workspace: workspace, Desktop: allocate.created[0]}) {
		t.Fatalf("new durable display was not allocated and attached: %+v", allocate)
	}
}

func TestAutomaticDisplaySelectionNeverRetriesUnknownOrExplicitRefusal(t *testing.T) {
	workspace := strings.Repeat("a", 32)
	first, second := strings.Repeat("b", 32), strings.Repeat("c", 32)
	catalog := hive.DesktopCatalog{Desktops: []hive.DesktopDescription{{ID: first, IsDefault: true}, {ID: second}}}
	unknown := errors.New("transport lost")
	script := &desktopScript{attachErrors: []error{unknown}}
	if _, err := attachDesktop(context.Background(), script, catalog, workspace, Selection{}, hive.Control); err != unknown || len(script.attached) != 1 || len(script.created) != 0 {
		t.Fatalf("unknown result was retried: calls=%+v created=%+v err=%v", script.attached, script.created, err)
	}
	explicit := &desktopScript{attachErrors: []error{&hive.Rejected{Fault: hive.Fault{Code: "DESKTOP_CONTROLLED"}}}}
	selected := Selection{Workspace: workspace, Desktop: second}
	if _, err := attachDesktop(context.Background(), explicit, catalog, workspace, selected, hive.Control); err == nil || len(explicit.attached) != 1 || explicit.attached[0] != selected || len(explicit.created) != 0 {
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
	err = Operate(context.Background(), Config{Directory: directory, EnrollmentDir: directory}, "client", key, func(context.Context, *hive.Join, rendezvous.Descriptor) error {
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
