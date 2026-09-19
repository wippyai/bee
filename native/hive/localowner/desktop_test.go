//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package localowner_test

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	hiveclient "github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/desktop"
	"github.com/wippyai/bee/native/hive/localowner"
	"github.com/wippyai/bee/native/hive/rendezvous"
	beelaunch "github.com/wippyai/bee/native/launch"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/tty"
	stackpkg "github.com/wippyai/runtime/cluster"
	app "github.com/wippyai/runtime/cmd/app"
)

const DirectoryName = localowner.DirectoryName

var physicalSessionProbe func(context.Context, string) error
var physicalStartupProbe func(context.Context, string) error

type desktopBundle struct {
	Bundle  app.Bundle
	DataEnv map[string]string
}

func TestFreshClientDesktopComposition(t *testing.T) {
	toolchain := os.Getenv("BEE_OWNER_TEST_WIPPY")
	if toolchain == "" {
		t.Skip("explicit owner toolchain required")
	}
	_, file, _, _ := runtime.Caller(0)
	repo := filepath.Clean(filepath.Join(filepath.Dir(file), "../../.."))
	if selected := os.Getenv("BEE_OWNER_TEST_SOURCE"); selected != "" {
		if !filepath.IsAbs(selected) {
			t.Fatal("BEE_OWNER_TEST_SOURCE must be absolute")
		}
		repo = selected
	}
	t.Logf("snapshotting Bee application source from %s", repo)
	stage := t.TempDir()
	if err := os.CopyFS(filepath.Join(stage, "src"), os.DirFS(filepath.Join(repo, "src"))); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stage, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
		t.Fatal(err)
	}
	planBytes, err := os.ReadFile(filepath.Join(repo, "build/modules.json"))
	if err != nil {
		t.Fatal(err)
	}
	var plan struct {
		Modules []struct {
			Module     string   `json:"module"`
			Namespaces []string `json:"namespaces"`
		} `json:"modules"`
	}
	if err := json.Unmarshal(planBytes, &plan); err != nil {
		t.Fatal(err)
	}
	bundle := app.Bundle{Root: "bee/bee"}
	for index, module := range plan.Modules {
		target := filepath.Join(stage, fmt.Sprintf("module-%d.wapp", index))
		parts := strings.Split(module.Module, "/")
		args := []string{"pack", target, "--meta", "namespace=" + strings.ReplaceAll(module.Module, "/", "."), "--meta", "name=" + parts[1], "--meta", "version=0.1.0-dev"}
		for _, other := range plan.Modules {
			if other.Module != module.Module {
				for _, namespace := range other.Namespaces {
					args = append(args, "--exclude-ns", namespace)
				}
			}
		}
		command := exec.Command(toolchain, args...)
		command.Dir = stage
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("pack %s: %v\n%s", module.Module, err, out)
		}
		data, err := os.ReadFile(target)
		if err != nil {
			t.Fatal(err)
		}
		bundle.Packs = append(bundle.Packs, app.Pack{Module: module.Module, Version: "0.1.0-dev", Digest: fmt.Sprintf("sha256:%x", sha256.Sum256(data)), Data: data})
	}
	pack := filepath.Join(stage, "bundle.json")
	manifestBytes, err := os.ReadFile(filepath.Join(repo, "wippy.build.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifestConfig struct {
		Application struct {
			DataEnv map[string]string `json:"data_env"`
		} `json:"application"`
	}
	if err := json.Unmarshal(manifestBytes, &manifestConfig); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(desktopBundle{Bundle: bundle, DataEnv: manifestConfig.Application.DataEnv})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pack, encoded, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	defer cancel()
	state := filepath.Join(stage, "state")
	t.Setenv("BEE_OWNER_DESKTOP_PACK", pack)
	t.Setenv("BEE_OWNER_DESKTOP_ENTRY", "1")
	log, err := os.OpenFile(filepath.Join(stage, "owner.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	child, err := beelaunch.StartOwner(ctx, app.Launch{
		Op: app.OpRun, Command: "bee", State: state, Dir: stage,
	}, log)
	if err != nil {
		t.Fatal(err)
	}
	done := child.Done()
	watcherDone := make(chan struct{})
	go func() {
		select {
		case <-done:
			cancel()
		case <-ctx.Done():
		}
		close(watcherDone)
	}()
	defer func() {
		_ = child.Abort()
		_ = child.Wait(context.Background())
		cancel()
		<-watcherDone
		if t.Failed() {
			data, _ := os.ReadFile(filepath.Join(stage, "owner.log"))
			t.Log(string(data))
		}
	}()
	store, err := rendezvous.New(filepath.Join(state, DirectoryName))
	if err != nil {
		t.Fatal(err)
	}
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		if _, err = store.Read(ctx); err == nil {
			break
		}
		select {
		case <-done:
			t.Fatalf("owner exited: %v", child.Wait(context.Background()))
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-ticker.C:
		}
	}
	err = mesh.SameAccount(ctx, filepath.Join(state, DirectoryName), func(life context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(life, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			for {
				if _, err := actor.OwnerSupervisor(frame); err == nil {
					break
				}
				select {
				case <-frame.Done():
					return frame.Err()
				case <-ticker.C:
				}
			}
			client, err := hiveclient.NewDesktop(frame, actor, owner.Node, owner.Execution)
			if err != nil {
				return err
			}
			var catalog hiveclient.DesktopCatalog
			for attempt := 0; ; attempt++ {
				catalog, err = client.List(frame, fmt.Sprintf("catalog-%d", attempt))
				if err == nil {
					break
				}
				var denied *hiveclient.Rejected
				if !errors.As(err, &denied) || denied.Fault.Code != "UNAVAILABLE" {
					return err
				}
				select {
				case <-frame.Done():
					return frame.Err()
				case <-ticker.C:
				}
			}
			if len(catalog.Workspaces) != 1 || len(catalog.Workspaces[0].Desktops) != 1 {
				return errors.New("missing retained desktop")
			}
			w := catalog.Workspaces[0]
			surface := tty.GetService(frame)
			if surface == nil {
				return errors.New("native viewport service unavailable")
			}
			for index := 0; index < 2; index++ {
				mount, err := client.Attach(frame, fmt.Sprintf("attach-%d", index), w.ID, w.Desktops[0].ID, hiveclient.Control)
				if err != nil {
					return err
				}
				view, err := surface.Attach(frame, mount.Mount)
				if err != nil {
					return err
				}
				defer view.Close()
				if err := awaitDesktopText(frame, view, "$ "); err != nil {
					return err
				}
				if index == 0 {
					forged := mount
					forged.Session = "another-session"
					if _, err := client.Copy(frame, "wrong-session-copy", forged); !copyDenied(err, "DENIED") {
						return fmt.Errorf("copy with substituted session was not denied: %v", err)
					}
					if err := probeObserverCopy(frame, filepath.Join(state, DirectoryName), w.ID, w.Desktops[0].ID); err != nil {
						return err
					}
				}
				command := "bee_probe=retained; printf 'BEE_OWNER_%s_OK\\n' \"$bee_probe\""
				expected := "BEE_OWNER_retained_OK"
				if index == 1 {
					command = "printf 'BEE_REJOIN_%s_OK\\n' \"$bee_probe\""
					expected = "BEE_REJOIN_retained_OK"
				}
				if err := view.Send(tty.Event{Type: "paste", Paste: command}); err != nil {
					return err
				}
				if err := view.Send(tty.Event{Type: "key", KeyType: "enter", Action: "press"}); err != nil {
					return err
				}
				if err := awaitDesktopText(frame, view, expected); err != nil {
					return err
				}
				if err := client.Detach(frame, fmt.Sprintf("detach-%d", index), mount); err != nil {
					return err
				}
				if _, err := client.Copy(frame, fmt.Sprintf("retired-copy-%d", index), mount); !copyDenied(err, "NOT_FOUND") {
					return fmt.Errorf("retired desktop session copied: %v", err)
				}
				if err := view.Send(tty.Event{Type: "paste", Paste: "forbidden"}); err == nil {
					return errors.New("retired mount accepted input")
				}
				if err := view.Close(); err != nil {
					return err
				}
			}
			return nil
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	if physicalSessionProbe != nil {
		if err := physicalSessionProbe(ctx, filepath.Join(state, DirectoryName)); err != nil {
			t.Fatal(err)
		}
	}

	if physicalStartupProbe != nil {
		t.Setenv("BEE_OWNER_TEST_EMPTY_DESKTOP", "1")
		coldState := filepath.Join(stage, "cold-state")
		defer stopRecordedFixtureOwner(t, coldState)
		if err := physicalStartupProbe(ctx, filepath.Join(coldState, DirectoryName)); err != nil {
			t.Fatal("automatic first launch:", err)
		}
	}
	probeConcurrentStarts(t, ctx, filepath.Join(stage, "concurrent-state"), stage)
}

func copyDenied(err error, code string) bool {
	var rejected *hiveclient.Rejected
	return errors.As(err, &rejected) && rejected.Fault.Code == code
}

// A second actual native client may observe the same retained desktop, but
// cannot read the controller's selection through its own observer session.
func probeObserverCopy(parent context.Context, directory, workspace, desktopID string) error {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	return mesh.SameAccount(ctx, directory, func(lifetime context.Context, stack *stackpkg.Stack, owner rendezvous.Descriptor) error {
		return mesh.WithActor(lifetime, stack, owner.Node, func(frame context.Context, actor *mesh.Actor) error {
			client, err := hiveclient.NewDesktop(frame, actor, owner.Node, owner.Execution)
			if err != nil {
				return err
			}
			mounted, err := client.Attach(frame, "observer-attach", workspace, desktopID, hiveclient.Observe)
			if err != nil {
				return err
			}
			if _, err := client.Copy(frame, "observer-copy", mounted); !copyDenied(err, "DENIED") {
				return fmt.Errorf("observer could request controller selection: %v", err)
			}
			return client.Detach(frame, "observer-detach", mounted)
		})
	})
}

// The helper re-enters the application's real argument parser before Go's test
// flags are parsed. StartOwner therefore invokes this executable exactly as the
// assembled Bee launcher will, rather than using a custom process fixture route.
func init() {
	if os.Getenv("BEE_OWNER_DESKTOP_ENTRY") != "1" {
		return
	}
	if err := runOwnerDesktop(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(0)
}

func runOwnerDesktop(args []string) error {
	data, err := os.ReadFile(os.Getenv("BEE_OWNER_DESKTOP_PACK"))
	if err != nil {
		return err
	}
	initial := "bee.console:app"
	if os.Getenv("BEE_OWNER_TEST_EMPTY_DESKTOP") == "1" {
		initial = ""
	}
	host, err := desktop.New(desktop.Options{Node: "owner-desktop", Lifetime: 90 * time.Second, Application: initial})
	if err != nil {
		return err
	}
	var bundle desktopBundle
	if err := json.Unmarshal(data, &bundle); err != nil {
		return err
	}
	return app.Run(context.Background(), app.Executable{
		Name: "bee-owner-desktop", Command: "bee", Bundle: bundle.Bundle,
		Components: []boot.Component{recordingHost{host}}, Data: bundle.DataEnv, Host: recordingHost{host},
	}, args)
}

func awaitDesktopText(ctx context.Context, view tty.Viewport, text string) error {
	timeout := time.NewTimer(5 * time.Second)
	defer timeout.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		if strings.Contains(strings.Join(view.Snapshot().Rows, "\n"), text) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timeout.C:
			return fmt.Errorf("desktop missing %q: %s", text, strings.Join(view.Snapshot().Rows, "\n"))
		case <-tick.C:
		}
	}
}

func stopRecordedFixtureOwner(t *testing.T, state string) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(state, "owner-test-pid"))
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil {
		t.Error(err)
		return
	}
	pid, err := strconv.Atoi(string(data))
	if err != nil || pid <= 0 {
		t.Error("invalid fixture child PID")
		return
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		t.Error(err)
		return
	}
	defer process.Release()
	if err := process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		t.Error(err)
	}
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		owned, err := app.Owned(state)
		if err == nil && !owned {
			return
		}
		if err != nil {
			t.Error(err)
			return
		}
		select {
		case <-deadline.C:
			t.Error("fixture owner did not release lock after cleanup")
			return
		case <-tick.C:
		}
	}
}

// Record only the test child actually elected under the application lock, for
// bounded cleanup of a cold owner started by the automatic foreground route.
type recordingHost struct{ *desktop.Host }

func (h recordingHost) Plan(ctx context.Context, launch app.Launch) (app.Plan, error) {
	plan, err := h.Host.Plan(ctx, launch)
	if err != nil || plan.Prepare == nil {
		return plan, err
	}
	prepare := plan.Prepare
	state := launch.State
	plan.Prepare = func(ctx context.Context) (boot.Config, func() error, error) {
		if err := os.WriteFile(filepath.Join(state, "owner-test-pid"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
			return nil, nil, err
		}
		if os.Getenv("BEE_OWNER_TEST_PREPARE_DELAY") == "1" {
			select {
			case <-ctx.Done():
				return nil, nil, ctx.Err()
			case <-time.After(time.Second):
			}
		}
		return prepare(ctx)
	}
	return plan, nil
}

func probeConcurrentStarts(t *testing.T, ctx context.Context, state, project string) {
	t.Helper()
	t.Setenv("BEE_OWNER_TEST_PREPARE_DELAY", "1")
	children := make([]*beelaunch.OwnerProcess, 0, 2)
	logs := []string{}
	defer func() {
		for _, child := range children {
			_ = child.Abort()
		}
		for _, child := range children {
			_ = child.Wait(context.Background())
		}
		if t.Failed() {
			for _, name := range logs {
				data, _ := os.ReadFile(name)
				t.Log(string(data))
			}
		}
	}()
	for i := 0; i < 2; i++ {
		log, err := os.CreateTemp(project, "concurrent-owner-")
		if err != nil {
			t.Fatal(err)
		}
		defer log.Close()
		logs = append(logs, log.Name())
		child, err := beelaunch.StartOwner(ctx, app.Launch{Op: app.OpRun, Command: "bee", State: state, Dir: project}, log)
		if err != nil {
			t.Fatal(err)
		}
		children = append(children, child)
	}
	var loser, winner *beelaunch.OwnerProcess
	select {
	case <-children[0].Done():
		loser, winner = children[0], children[1]
	case <-children[1].Done():
		loser, winner = children[1], children[0]
	case <-ctx.Done():
		t.Fatal("concurrent start did not converge", ctx.Err())
	}
	if err := loser.Wait(ctx); err != nil {
		t.Fatal("losing start failed before owner publication:", err)
	}
	select {
	case <-winner.Done():
		t.Fatal("both owner contenders exited", winner.Wait(ctx))
	default:
	}
	owned, err := app.Owned(state)
	if err != nil {
		t.Fatal(err)
	}
	if !owned {
		t.Fatal("successful start has no owner lock")
	}
}
