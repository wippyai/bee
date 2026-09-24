// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	app "github.com/wippyai/runtime/cmd/app"
)

// ownerPIDName records the operating-system process of the owner that holds
// the state. The owner writes it under the state lock and removes it on release.
const ownerPIDName = "owner.pid"

const stopArgument = "stop"

// stopSeams are the owner lock probe, the graceful stop signal and the wait
// bounds of one bee stop.
type stopSeams struct {
	owned    func(state string) (bool, error)
	signal   func(pid int) error
	interval time.Duration
	timeout  time.Duration
}

func defaultStopSeams() stopSeams {
	return stopSeams{owned: app.Owned, signal: signalOwner, interval: waitPollInterval, timeout: 2 * time.Minute}
}

// recordOwnerProcess writes this process as the state's owner and returns the
// release that removes the record.
func recordOwnerProcess(state string) (func() error, error) {
	path := filepath.Join(ownerDirectory(state), ownerPIDName)
	if err := writeOwnerFile(path, []byte(strconv.Itoa(os.Getpid())+"\n")); err != nil {
		return nil, err
	}
	return func() error {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}, nil
}

func readOwnerProcess(state string) (int, error) {
	data, err := os.ReadFile(filepath.Join(ownerDirectory(state), ownerPIDName))
	if err != nil {
		return 0, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0, fmt.Errorf("owner process record is malformed: %q", strings.TrimSpace(string(data)))
	}
	return pid, nil
}

// stopOwner asks this project's owner to shut down gracefully and reports once
// it no longer holds the state. The runtime's own shutdown saves and retires
// the desktop exactly as a signal to the foreground owner does.
func stopOwner(ctx context.Context, state string, report io.Writer, seams stopSeams) error {
	owned, err := seams.owned(state)
	if err != nil {
		return err
	}
	if !owned {
		_, err := fmt.Fprintln(report, "Bee is not running for this project")
		return err
	}
	pid, err := readOwnerProcess(state)
	if err != nil {
		return fmt.Errorf("the running Bee recorded no owner process: %w", err)
	}
	if _, err := fmt.Fprintln(report, "Stopping Bee…"); err != nil {
		return err
	}
	if err := seams.signal(pid); err != nil {
		return fmt.Errorf("stop Bee owner %d: %w", pid, err)
	}
	deadline := time.Now().Add(seams.timeout)
	for {
		owned, err := seams.owned(state)
		if err != nil {
			return err
		}
		if !owned {
			_, err := fmt.Fprintln(report, "Bee stopped")
			return err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("Bee owner %d did not stop within %s", pid, seams.timeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(seams.interval):
		}
	}
}
