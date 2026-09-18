// SPDX-License-Identifier: MIT
package computer

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/wippyai/bee/native/computer/driver"
	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	runtimeapi "github.com/wippyai/runtime/api/runtime"
	sec "github.com/wippyai/runtime/api/security"
)

func TestMain(m *testing.M) {
	configureInputFault()
	if len(os.Args) == 2 {
		if handled, err := driver.InputRole(os.Args[1]); handled {
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			os.Exit(0)
		}
	}

	if len(os.Args) == 2 && os.Args[1] == "--bee-computer-driver" {
		if runtime.GOOS == "windows" {
			if err := driver.Run(); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			os.Exit(0)
		}
		// Linux protocol fixture; never claims native desktop coverage.
		scanner := bufio.NewScanner(os.Stdin)
		encoder := json.NewEncoder(os.Stdout)
		endpoint := fmt.Sprintf("%032d", os.Getpid())
		for scanner.Scan() {
			var q driver.Request
			if json.Unmarshal(scanner.Bytes(), &q) != nil {
				os.Exit(2)
			}
			if q.Op == "act" && len(q.Actions) == 1 && q.Actions[0].Text == "fixture-stall" {
				time.Sleep(20 * time.Second)
			}
			r := driver.Reply{ID: q.ID, Endpoint: endpoint, Session: "fixture-session", Frame: "fixture-frame", Width: 10, Height: 10}
			if q.Op == "act" {
				r.Error = "stale or invalid frame"
			}
			if encoder.Encode(r) != nil {
				os.Exit(2)
			}
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

type exactScope struct {
	resource string
	actions  map[string]bool
}

func (s *exactScope) With(sec.Policy) sec.Scope     { return s }
func (s *exactScope) Without(registry.ID) sec.Scope { return s }
func (s *exactScope) Contains(registry.ID) bool     { return false }
func (s *exactScope) Policies() []sec.Policy        { return nil }
func (s *exactScope) Evaluate(_ sec.Actor, a, r string, _ attrs.Bag) sec.Result {
	if r == s.resource && s.actions[a] {
		return sec.Allow
	}
	return sec.Deny
}
func caller(t *testing.T, node, id, resource string, actions ...string) context.Context {
	t.Helper()
	ctx, f := ctxapi.OpenFrameContext(ctxapi.NewRootContext())
	t.Cleanup(func() { f.Close() })
	if err := runtimeapi.SetFramePID(ctx, pid.PID{Node: node, Host: "workers", UniqID: id}); err != nil {
		t.Fatal(err)
	}
	if err := sec.SetActor(ctx, sec.Actor{ID: "test-agent"}); err != nil {
		t.Fatal(err)
	}
	scope := &exactScope{resource: resource, actions: map[string]bool{}}
	for _, a := range actions {
		scope.actions["bee.computer."+a] = true
	}
	if err := sec.SetScope(ctx, scope); err != nil {
		t.Fatal(err)
	}
	return ctx
}
func newOwner(t *testing.T) *Owner {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	o, err := New(exe, "node", "bee.computer:console", filepath.Join(t.TempDir(), "seat"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := o.Stop(ctx); err != nil && !errors.Is(err, ErrRecovery) {
			t.Error(err)
		}
	})
	return o
}
func TestOwnerPermissionsLifecycle(t *testing.T) {
	o := newOwner(t)
	all := []string{"control", "observe", "act"}
	for name, ctx := range map[string]context.Context{
		"no frame":       context.Background(),
		"missing grant":  caller(t, "node", "a", o.resource),
		"wrong resource": caller(t, "node", "a", "other", all...),
		"foreign node":   caller(t, "foreign", "a", o.resource, all...),
	} {
		if _, err := o.Open(ctx); !errors.Is(err, ErrDenied) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	ctx := caller(t, "node", "a", o.resource, all...)
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = o.Open(ctx); !errors.Is(err, ErrBusy) {
		t.Fatalf("second controller: %v", err)
	}
	q := driver.Request{Op: "observe"}
	sibling := caller(t, "node", "b", o.resource, all...)
	if _, _, err = l.Do(sibling, q); !errors.Is(err, ErrDenied) {
		t.Fatalf("sibling: %v", err)
	}
	denied := caller(t, "node", "a", o.resource, "control")
	if _, _, err = l.Do(denied, q); !errors.Is(err, ErrDenied) {
		t.Fatalf("scope revoked: %v", err)
	}
	observed, data, err := l.Do(ctx, q)
	if err != nil || observed.Error != "" || observed.Frame == "" {
		t.Fatalf("observe: %+v %v", observed, err)
	}
	if runtime.GOOS == "windows" && len(data) == 0 {
		t.Fatal("native capture empty")
	}
	t.Logf("observed %dx%d %d bytes", observed.Width, observed.Height, len(data))
	readOnly := caller(t, "node", "a", o.resource, "observe")
	if _, _, err = l.Do(readOnly, driver.Request{Op: "act", BasedOn: observed.Frame, Actions: []driver.Action{{Kind: "click", X: 1, Y: 1}}}); !errors.Is(err, ErrDenied) {
		t.Fatalf("read-only input: %v", err)
	}
	if err = o.Revoke(ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, err = l.Do(ctx, q); !errors.Is(err, ErrRetired) {
		t.Fatalf("revoked: %v", err)
	}
	fresh, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.endpoint == l.endpoint {
		t.Fatal("restart reused endpoint")
	}
	if _, _, err = l.Do(ctx, q); !errors.Is(err, ErrRetired) {
		t.Fatalf("old lease after restart: %v", err)
	}
	reply, _, err := fresh.Do(ctx, driver.Request{Op: "act", BasedOn: observed.Frame, Actions: []driver.Action{{Kind: "click", X: 1, Y: 1}}})
	if err != nil || reply.Error != "stale or invalid frame" {
		t.Fatalf("old frame after restart: %+v %v", reply, err)
	}
	if _, _, err = fresh.Do(ctx, q); err != nil {
		t.Fatal(err)
	}
	t.Log("denials, revocation, restart, old grant and old frame rejection passed")
}
func TestCallerExitKillsDriver(t *testing.T) {
	o := newOwner(t)
	ctx := caller(t, "node", "a", o.resource, "control", "observe")
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	select {
	case <-l.exited:
	case <-time.After(3 * time.Second):
		t.Fatal("child survived caller cancellation")
	}
}
func TestDriverCrashRetiresLease(t *testing.T) {
	o := newOwner(t)
	ctx := caller(t, "node", "a", o.resource, "control", "observe")
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err = l.cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	<-l.exited
	if _, _, err = l.Do(ctx, driver.Request{Op: "observe"}); !errors.Is(err, ErrRetired) {
		t.Fatal(err)
	}
	fresh, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.endpoint == l.endpoint {
		t.Fatal("crash reused endpoint")
	}
}
func TestDesktopLoss(t *testing.T) {
	if runtime.GOOS != "windows" || os.Getenv("BEE_COMPUTER_DESKTOP_TEST") != "1" {
		t.Skip("requires external Windows desktop switch")
	}
	o := newOwner(t)
	ctx := caller(t, "node", "a", o.resource, "control", "observe")
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = l.Do(ctx, driver.Request{Op: "observe"}); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile("desktop.ready", []byte("ready"), 0600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-l.exited:
	case <-time.After(20 * time.Second):
		t.Fatal("child survived desktop loss")
	}
	if _, _, err = l.Do(ctx, driver.Request{Op: "observe"}); !errors.Is(err, ErrRetired) {
		t.Fatal(err)
	}
	if _, err = o.Open(ctx); !errors.Is(err, ErrRetired) {
		t.Fatalf("new open on secure desktop: %v", err)
	}
	t.Log("idle child exited and old grant retired on desktop loss; new open denied")
}

func TestTimeoutDoesNotReplay(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Linux stalled-transport fixture")
	}
	o := newOwner(t)
	ctx := caller(t, "node", "a", o.resource, "control", "observe", "act")
	l, err := o.Open(ctx)
	if err != nil {
		t.Fatal(err)
	}
	op, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	_, _, err = l.Do(op, driver.Request{Op: "act", Actions: []driver.Action{{Kind: "text", Text: "fixture-stall"}}})
	if !errors.Is(err, ErrUncertain) {
		t.Fatalf("timeout: %v", err)
	}
	if _, _, err = l.Do(ctx, driver.Request{Op: "observe"}); !errors.Is(err, ErrRetired) {
		t.Fatalf("timed-out endpoint: %v", err)
	}
	select {
	case <-l.exited:
	case <-time.After(3 * time.Second):
		t.Fatal("timed-out child survived")
	}
}
