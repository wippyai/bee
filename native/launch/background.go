//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	app "github.com/wippyai/runtime/cmd/app"
)

// OwnerProcess is a child executable, not proof of workspace ownership or
// readiness. The runtime's application lock arbitrates ownership; native mesh
// admission establishes readiness. The parent reaps the child while it lives.
type OwnerProcess struct {
	command *exec.Cmd
	done    chan struct{}
	result  error // published by closing done
}

// StartOwner starts this executable's headless start route in a separate OS
// session. It preserves the selected state and project directory. The caller
// supplies a protected log file; no pipe keeps the owner tied to the client.
// An already canceled context prevents creation. After success, foreground
// cancellation or exit must not terminate the owner or its applications.
func StartOwner(ctx context.Context, request app.LaunchRequest, log *os.File) (*OwnerProcess, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	command, err := ownerCommand(executable, request, log)
	if err != nil {
		return nil, err
	}
	return startDetached(ctx, command)
}

func ownerCommand(executable string, request app.LaunchRequest, log *os.File) (*exec.Cmd, error) {
	if !filepath.IsAbs(executable) || request.Command == "" || len(request.Arguments) != 0 || !filepath.IsAbs(request.StateDir) ||
		!filepath.IsAbs(request.Directory) || log == nil {
		return nil, errors.New("invalid background Bee owner launch")
	}
	info, err := log.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("owner output must be a regular log file")
	}
	command := exec.Command(executable, "--state-dir", request.StateDir, "--command", request.Command, "run", "start")
	command.Dir = request.Directory
	command.Stdout, command.Stderr = log, log
	// A nil stdin is /dev/null. Never inherit the client's controlling terminal.
	return command, nil
}

func startDetached(ctx context.Context, command *exec.Cmd) (*OwnerProcess, error) {
	if ctx == nil {
		return nil, errors.New("owner launch requires a context")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := detachOwner(command); err != nil {
		return nil, err
	}
	if err := command.Start(); err != nil {
		return nil, fmt.Errorf("start Bee owner: %w", err)
	}
	child := &OwnerProcess{command: command, done: make(chan struct{})}
	go func() { child.result = command.Wait(); close(child.done) }()
	return child, nil
}

// Done closes when this child exits. A child may lose the ownership race, so its
// existence or exit alone must never authorize an attachment or owner takeover.
func (p *OwnerProcess) Done() <-chan struct{} { return p.done }

// Wait observes exit without tying owner lifetime to the observation context.
func (p *OwnerProcess) Wait(ctx context.Context) error {
	if ctx == nil {
		return errors.New("owner wait requires a context")
	}
	select {
	case <-p.done:
		return p.result
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Abort force-stops only the child created by this launcher. It is for explicit
// startup abandonment or fixture cleanup, never foreground detach. Wait must
// still observe completion; this is not a workspace shutdown/admission API.
func (p *OwnerProcess) Abort() error { return p.command.Process.Kill() }
