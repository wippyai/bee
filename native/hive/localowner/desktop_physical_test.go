//go:build meshclient && physicalclient && !windows

// SPDX-License-Identifier: MIT
package localowner_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/wippyai/bee/native/client/hive"
	beelaunch "github.com/wippyai/bee/native/launch"
	applicationapi "github.com/wippyai/runtime/api/application"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/application"
)

type sessionOutput struct {
	sync.Mutex
	bytes.Buffer
}

func (b *sessionOutput) Write(data []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	return b.Buffer.Write(data)
}
func (b *sessionOutput) text() string { b.Lock(); defer b.Unlock(); return b.Buffer.String() }

func init() {
	physicalSessionProbe = probePhysicalSession
	physicalStartupProbe = func(ctx context.Context, directory string) error {
		return probePhysicalSessionMode(ctx, directory, true, true)
	}
}

func probePhysicalSession(parent context.Context, directory string) error {
	if err := probePhysicalSessionMode(parent, directory, false, false); err != nil {
		return err
	}
	return probePhysicalSessionMode(parent, directory, true, false)
}

func probePhysicalSessionMode(parent context.Context, directory string, automatic, initialize bool) error {
	ctx, cancel := context.WithTimeout(parent, 20*time.Second)
	defer cancel()
	master, slave, err := pty.Open()
	if err != nil {
		return err
	}
	defer master.Close()
	defer slave.Close()
	if err := pty.Setsize(slave, &pty.Winsize{Rows: 32, Cols: 100}); err != nil {
		return err
	}
	var output sessionOutput
	done := make(chan struct{})
	var sessionErr error
	go func() {
		adapter := beelaunch.Client{Command: "bee", Mode: hive.Control, Stdin: slave, Stdout: &output}
		var launcher boot.Component = busyClientLauncher{adapter}
		if automatic {
			selected, err := beelaunch.NewLauncher(adapter, "bee-owner", func(context.Context, applicationapi.LaunchRequest) (applicationapi.OwnerPlan, error) {
				return applicationapi.OwnerPlan{}, errors.New("foreground client must not become owner")
			})
			if err != nil {
				sessionErr = err
				close(done)
				return
			}
			launcher = selected
		}
		// Invalid data binding and empty bundle would fail on the owner path.
		// A live owner's real application lock must route directly to Attach.
		sessionErr = application.Run(ctx, application.Options{
			Name: "bee-owner-desktop", Mode: "base", Command: "bee",
			DataEnv:    map[string]string{"INVALID=BINDING": "never-opened.db"},
			Components: []boot.Component{launcher},
		}, []string{"--state-dir", filepath.Dir(directory)})
		close(done)
	}()
	defer func() { cancel(); <-done }()
	await := func(marker string) error {
		timeout := time.NewTimer(10 * time.Second)
		defer timeout.Stop()
		tick := time.NewTicker(10 * time.Millisecond)
		defer tick.Stop()
		for {
			if strings.Contains(output.text(), marker) {
				return nil
			}
			select {
			case <-done:
				return fmt.Errorf("session stopped before %q: %v", marker, sessionErr)
			case <-ctx.Done():
				return ctx.Err()
			case <-timeout.C:
				return fmt.Errorf("physical session missing %q", marker)
			case <-tick.C:
			}
		}
	}
	if err := await("$ "); err != nil {
		return err
	}
	// The prior client set this variable. Its literal value is not in the command.
	command := "printf 'BEE_PHYSICAL_%s_OK\\n' \"$bee_probe\"\r"
	if initialize {
		command = "bee_probe=retained; " + command
	}
	if _, err := master.Write([]byte(command)); err != nil {
		return err
	}
	if err := await("BEE_PHYSICAL_retained_OK"); err != nil {
		return err
	}
	if _, err := master.Write([]byte{0x1d}); err != nil {
		return err
	}
	select {
	case <-done:
		return sessionErr
	case <-ctx.Done():
		return errors.New("physical detach did not finish")
	}
}

// This host wrapper supplies the real attachment adapter and fails immediately
// if the runtime accidentally takes the owner path while the other process lives.
type busyClientLauncher struct{ client beelaunch.Client }

func (busyClientLauncher) Name() string        { return "bee.test.busy_client" }
func (busyClientLauncher) DependsOn() []string { return nil }
func (busyClientLauncher) Load(ctx context.Context) (context.Context, error) {
	return ctx, errors.New("busy client must not boot runtime components")
}
func (c busyClientLauncher) PrepareLaunch(context.Context, applicationapi.LaunchRequest) (applicationapi.LaunchPlan, error) {
	return applicationapi.LaunchPlan{Attach: c.client.Attach, PrepareOwner: func(context.Context, applicationapi.LaunchRequest) (applicationapi.OwnerPlan, error) {
		return applicationapi.OwnerPlan{}, errors.New("busy client must not prepare another owner")
	}}, nil
}
