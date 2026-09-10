//go:build meshclient

// SPDX-License-Identifier: MIT
package localowner

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	hiveclient "github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/ioevents"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/application"
	stackpkg "github.com/wippyai/runtime/cluster"
)

var physicalSessionProbe func(context.Context, string) error

type desktopBundle struct {
	Bundle  application.Bundle
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
	fixture := filepath.Join(stage, "src", "owner_fixture")
	if err := os.Mkdir(fixture, 0700); err != nil {
		t.Fatal(err)
	}
	manifest := `version: '1.0'
namespace: bee
entries:
- name: owner_fixture_names
  kind: security.policy
  policy:
    actions: [process.registry.register, process.registry.register.local, process.registry.register.eventual, process.registry.lookup, process.registry.unregister]
    resources: '*'
    effect: allow
- name: owner_fixture_execute
  kind: security.policy
  policy:
    actions: [funcs.call]
    resources: [bee.hive.supervisor:execute]
    effect: allow
- name: owner_fixture_main
  kind: process.lua
  source: file://main.lua
  method: main
  modules: [process]
  meta:
    command:
      name: owner-desktop-proof
`
	if err := os.WriteFile(filepath.Join(fixture, "_index.yaml"), []byte(manifest), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fixture, "main.lua"), []byte(`local process = require("process")
local function main()
 local events, err = process.events()
 if not events then error(tostring(err)) end
 while true do
  local event = events:receive()
  if not event or event.kind == process.event.CANCEL then return 0 end
 end
end
return {main = main}`), 0600); err != nil {
		t.Fatal(err)
	}
	activation := filepath.Join(stage, "src", "hive_activation")
	if err := os.Mkdir(activation, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(activation, "_index.yaml"), []byte("version: '1.0'\nnamespace: bee.hive\nentries:\n- name: activation\n  kind: bee.hive.activation\n"), 0600); err != nil {
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
	bundle := application.Bundle{Root: "bee/bee"}
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
		bundle.Packs = append(bundle.Packs, application.Pack{Module: module.Module, Version: "0.1.0-dev", Digest: fmt.Sprintf("sha256:%x", sha256.Sum256(data)), Data: data})
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
	var cmd *exec.Cmd
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(stage, "state")
	cmd = exec.CommandContext(ctx, executable, "-test.run=^TestOwnerDesktopSubprocess$")
	cmd.Env = append(os.Environ(), "BEE_OWNER_DESKTOP_PACK="+pack, "BEE_OWNER_DESKTOP_STATE="+state)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	var exitErr error
	go func() { exitErr = cmd.Wait(); close(done); cancel() }()
	defer func() {
		_ = cmd.Process.Kill()
		<-done
		if t.Failed() {
			t.Log(output.String())
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
			t.Fatalf("owner exited: %v\n%s", exitErr, output.String())
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
}

func TestOwnerDesktopSubprocess(t *testing.T) {
	pack := os.Getenv("BEE_OWNER_DESKTOP_PACK")
	if pack == "" {
		t.Skip("subprocess helper")
	}
	data, err := os.ReadFile(pack)
	if err != nil {
		t.Fatal(err)
	}
	owner, err := New(Options{Node: "owner-desktop", Lifetime: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	service, err := owner.DesktopService([]string{"bee:hive_supervisor_policy", "bee:hive_catalog_policy", "bee:hive_exposure_policy", "bee:hive_dispatch_policy", "bee:owner_fixture_names", "bee:owner_fixture_execute", "bee.hive.desktop:host_policy"}, "bee.console:app")
	if err != nil {
		t.Fatal(err)
	}
	var bundle desktopBundle
	if err := json.Unmarshal(data, &bundle); err != nil {
		t.Fatal(err)
	}
	err = application.Run(context.Background(), application.Options{Name: "bee-owner-desktop", Mode: "base", Command: "owner-desktop-proof", Bundle: bundle.Bundle, Components: []boot.Component{testLauncher{owner}, service, ioevents.Component()}, DataEnv: bundle.DataEnv}, []string{"--state-dir", os.Getenv("BEE_OWNER_DESKTOP_STATE")})
	if err != nil {
		t.Fatal(err)
	}
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
