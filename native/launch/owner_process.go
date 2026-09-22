//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"

	"github.com/wippyai/bee/native/internal/privatefile"
	app "github.com/wippyai/runtime/cmd/app"
)

var errRelativeOwnerLaunch = errors.New("detached owner requires absolute state and project directories")

// execOwnerCommand builds the ordinary-start grammar for a detached owner: the
// leading --state selects the directory and the child's own "start" argument
// selects the retained owner route the host plans for it.
func execOwnerCommand(executable string, launch app.Launch, log *os.File) *exec.Cmd {
	command := exec.Command(executable, "--state", launch.State, "run", "start")
	command.Dir = launch.Dir
	command.Stdout, command.Stderr = log, log
	return command
}

// startDetachedCommand starts a command in its own session so it survives this
// client's exit, and reaps it while this process lives.
func startDetachedCommand(ctx context.Context, command *exec.Cmd) (<-chan struct{}, func() error, error) {
	if ctx == nil {
		return nil, nil, errors.New("owner launch requires a context")
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	if err := detachOwner(command); err != nil {
		return nil, nil, err
	}
	if err := command.Start(); err != nil {
		return nil, nil, fmt.Errorf("start Bee owner: %w", err)
	}
	done := make(chan struct{})
	var result error
	go func() { result = command.Wait(); close(done) }()
	return done, func() error { return result }, nil
}

func openOwnerLog(state string) (*os.File, error) {
	if err := os.MkdirAll(state, 0o700); err != nil {
		return nil, err
	}
	log, err := os.CreateTemp(state, "owner-*.log")
	if err != nil {
		return nil, err
	}
	if err := privatefile.SetOwnerOnlyPermissions(log.Name()); err != nil {
		_ = log.Close()
		return nil, err
	}
	return log, nil
}
