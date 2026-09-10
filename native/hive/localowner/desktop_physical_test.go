//go:build meshclient && physicalclient && !windows

// SPDX-License-Identifier: MIT
package localowner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/session"
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

func init() { physicalSessionProbe = probePhysicalSession }

func probePhysicalSession(parent context.Context, directory string) error {
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
		sessionErr = session.Join(ctx, session.Config{Directory: directory, Mode: hive.Control}, slave, &output)
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
	if _, err := master.Write([]byte("printf 'BEE_PHYSICAL_%s_OK\\n' \"$bee_probe\"\r")); err != nil {
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
