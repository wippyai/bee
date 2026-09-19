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

	vt "github.com/charmbracelet/x/vt"
	"github.com/creack/pty"
	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/physical"
	beelaunch "github.com/wippyai/bee/native/launch"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/tty"
	app "github.com/wippyai/runtime/cmd/app"
	"golang.org/x/term"
)

type sessionOutput struct {
	sync.Mutex
	bytes.Buffer
	screen *vt.SafeEmulator
}

func (b *sessionOutput) Write(data []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	if b.screen != nil {
		if _, err := b.screen.Write(data); err != nil {
			return 0, err
		}
	}
	return b.Buffer.Write(data)
}
func (b *sessionOutput) text() string { b.Lock(); defer b.Unlock(); return b.Buffer.String() }

func init() {
	physicalSessionProbe = probePhysicalSession
	physicalStartupProbe = func(ctx context.Context, directory string) error {
		if err := probePhysicalSessionMode(ctx, directory, true, true); err != nil {
			return err
		}
		if os.Getenv("BEE_OWNER_TEST_COPY") == "1" {
			return probePhysicalSessionMode(ctx, directory, true, false)
		}
		return nil
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
	if os.Getenv("BEE_OWNER_TEST_COPY") == "1" {
		output.screen = vt.NewSafeEmulator(100, 32)
		output.screen.SetScrollbackSize(1)
	}
	done := make(chan struct{})
	var sessionErr error
	go func() {
		adapter := beelaunch.Client{Command: "bee", Mode: hive.Control, Stdin: slave, Stdout: &output}
		var launcher boot.Component = busyClientLauncher{adapter}
		var host app.Host = busyClientLauncher{adapter}
		if automatic {
			selected, err := beelaunch.NewLauncher(adapter, "bee-owner", func(context.Context, app.Launch) (boot.Config, func() error, error) {
				return nil, nil, errors.New("foreground client must not become owner")
			})
			if err != nil {
				sessionErr = err
				close(done)
				return
			}
			launcher, host = selected, selected
		}
		// A data binding and an empty bundle would both fail on the owner path;
		// the live owner's real application lock must route this launch to the
		// client route, which never opens state or boots components.
		sessionErr = app.Run(ctx, app.Executable{
			Name: "bee-owner-desktop", Command: "bee",
			Data:       map[string]string{"BEE_OWNER_PROBE_DB": "never-opened.db"},
			Components: []boot.Component{launcher}, Host: host,
		}, []string{"--state", filepath.Dir(directory)})
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
		if os.Getenv("BEE_OWNER_TEST_COPY") == "1" {
			if err := probeSelectedCopy(ctx, master, &output, done, func() error { return sessionErr }); err != nil {
				return err
			}
		}
	}
	if !initialize && os.Getenv("BEE_OWNER_TEST_COPY") == "1" && strings.Contains(output.text(), "\x1b]52;") {
		return errors.New("rejoined physical client replayed clipboard output")
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

// Plan attaches through the real client adapter when another invocation holds
// the state, and otherwise leaves the owner path looking unprepared, so the
// runtime's own lock-busy error is still exercised. Load fails if the runtime
// ever boots components on this route.
func (c busyClientLauncher) Plan(ctx context.Context, l app.Launch) (app.Plan, error) {
	if l.Op != app.OpRun {
		return app.Plan{}, nil
	}
	owned, err := app.Owned(l.State)
	if err != nil {
		return app.Plan{}, err
	}
	if !owned {
		return app.Plan{Prepare: func(context.Context) (boot.Config, func() error, error) {
			return nil, nil, errors.New("busy client must not prepare another owner")
		}}, nil
	}
	return app.Plan{Run: func(ctx context.Context) error { return c.client.Attach(ctx, l) }}, nil
}
