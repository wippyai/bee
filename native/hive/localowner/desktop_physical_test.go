//go:build meshclient && physicalclient && !windows

// SPDX-License-Identifier: MIT
package localowner_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/physical"
	beelaunch "github.com/wippyai/bee/native/launch"
	applicationapi "github.com/wippyai/runtime/api/application"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/application"
	"golang.org/x/term"
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
		return fmt.Errorf("direct attachment: %w", err)
	}
	if err := probePhysicalSessionExit(parent, directory, true, false, true); err != nil {
		return fmt.Errorf("signal exit: %w", err)
	}
	if err := probePhysicalSessionMode(parent, directory, true, false); err != nil {
		return fmt.Errorf("reattach after signal: %w", err)
	}
	return nil
}

func probePhysicalSessionMode(parent context.Context, directory string, automatic, initialize bool) error {
	return probePhysicalSessionExit(parent, directory, automatic, initialize, false)
}

func probePhysicalSessionExit(parent context.Context, directory string, automatic, initialize, signalExit bool) error {
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
	before, err := term.GetState(int(slave.Fd()))
	if err != nil {
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
				frame := output.text()
				if len(frame) > 2000 {
					frame = frame[len(frame)-2000:]
				}
				return fmt.Errorf("physical session missing %q; output tail %q", marker, frame)
			case <-tick.C:
			}
		}
	}
	if initialize {
		if err := await(" BEE "); err != nil {
			return err
		}
		if strings.Contains(output.text(), "$ ") {
			return errors.New("fresh desktop unexpectedly started a shell")
		}
		if _, err := master.Write([]byte("\x1bOP")); err != nil {
			return err
		}
		if err := await("Terminal"); err != nil {
			return err
		}
		if _, err := master.Write([]byte("\r")); err != nil {
			return err
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
	if initialize {
		if _, err := master.Write([]byte("printf 'BEE_INTERRUPT_%s_READY\\n' wait; sleep 20\r")); err != nil {
			return err
		}
		if err := await("BEE_INTERRUPT_wait_READY"); err != nil {
			return err
		}
		if _, err := master.Write([]byte{3}); err != nil {
			return err
		}
		if _, err := master.Write([]byte("printf 'BEE_INTERRUPT_%s_DONE\\n' good\r")); err != nil {
			return err
		}
		if err := await("BEE_INTERRUPT_good_DONE"); err != nil {
			return err
		}
	}
	if signalExit {
		// This is the isolated Go test process, whose foreground launch has already
		// installed NotifyContext. The owner is a different detached OS process.
		if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
			return err
		}
	} else if _, err := master.Write([]byte{0x1d}); err != nil {
		return err
	}
	select {
	case <-done:
		after, err := term.GetState(int(slave.Fd()))
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(before, after) {
			return errors.New("physical client did not restore terminal settings")
		}
		if signalExit && errors.Is(sessionErr, context.Canceled) {
			return nil
		}
		var delivery *physical.DeliveryError
		if signalExit && errors.As(sessionErr, &delivery) && errors.Is(delivery, tty.ErrMountExpired) {
			// A signal can interrupt the last native input acknowledgement. The
			// product reports this error; the proof must still verify restoration
			// and a fresh retained-shell rejoin rather than erase the failure.
			return nil
		}
		return sessionErr
	case <-ctx.Done():
		return errors.New("physical client exit did not finish")
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
