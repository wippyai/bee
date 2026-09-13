// SPDX-License-Identifier: MIT

// Package docker supplies a PTY for an existing, admitted Docker container.
// Container creation, authorization and durable lifecycle records belong to
// its caller. This package never creates, starts or removes a container.
package docker

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/moby/moby/api/types/container"
	"github.com/moby/moby/client"
	execapi "github.com/wippyai/runtime/api/service/exec"
)

// Identity is captured by the admitting component, not accepted as authority
// from an application request. IDs identify the daemon's actual objects.
type Identity struct {
	Labels      map[string]string
	ContainerID string
	ImageID     string
	StartedAt   string
}

// Attachment owns only its attached connection and wait. The caller owns cli.
type Attachment struct {
	ctx        context.Context
	cli        *client.Client
	connection *client.ContainerAttachResult
	cancelWait context.CancelFunc
	identity   Identity
	mu         sync.Mutex
	started    bool
	stopped    bool
}

const controlTimeout = 5 * time.Second

var _ execapi.PTYProcess = (*Attachment)(nil)
var _ execapi.WaitCanceler = (*Attachment)(nil)
var _ execapi.StdinCloser = (*Attachment)(nil)

func hexID(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// New performs no daemon I/O. The caller must authorize this daemon and exact
// container before calling it. Start verifies the admitted facts against Docker.
func New(ctx context.Context, cli *client.Client, expected Identity) (*Attachment, error) {
	if ctx == nil || cli == nil || !hexID(expected.ContainerID) || len(expected.ImageID) != 71 || expected.ImageID[:7] != "sha256:" || !hexID(expected.ImageID[7:]) {
		return nil, errors.New("Docker attachment requires full container and image IDs")
	}
	if _, err := time.Parse(time.RFC3339Nano, expected.StartedAt); err != nil {
		return nil, errors.New("Docker attachment requires the admitted execution start time")
	}
	if len(expected.Labels) == 0 || len(expected.Labels) > 32 {
		return nil, errors.New("Docker attachment requires admitted labels")
	}
	labels := make(map[string]string, len(expected.Labels))
	for key, val := range expected.Labels {
		if key == "" || len(key) > 256 || val == "" || len(val) > 4096 {
			return nil, errors.New("invalid Docker attachment label")
		}
		labels[key] = val
	}
	expected.Labels = labels
	waitCtx, cancel := context.WithCancel(ctx)
	return &Attachment{ctx: waitCtx, cli: cli, identity: expected, cancelWait: cancel}, nil
}

func (p *Attachment) inspect(ctx context.Context) error {
	result, err := p.cli.ContainerInspect(ctx, p.identity.ContainerID, client.ContainerInspectOptions{})
	if err != nil {
		return err
	}
	actual := result.Container
	if actual.ID != p.identity.ContainerID || actual.Image != p.identity.ImageID || actual.Config == nil || actual.State == nil {
		return errors.New("Docker container identity changed")
	}
	if !actual.Config.Tty || !actual.Config.OpenStdin || !actual.Config.AttachStdin || actual.State.StartedAt != p.identity.StartedAt {
		return errors.New("Docker attachment requires a running container with an open PTY")
	}
	for key, val := range p.identity.Labels {
		if actual.Config.Labels[key] != val {
			return errors.New("Docker container admission labels changed")
		}
	}
	if actual.State.Status != container.StateRunning {
		if actual.State.Status == container.StateExited || actual.State.Status == container.StateDead {
			return os.ErrProcessDone
		}
		return errors.New("Docker attachment requires a running container")
	}
	return nil
}

func (p *Attachment) Start() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.started || p.stopped {
		return errors.New("Docker attachment is already used")
	}
	ctx, cancel := context.WithTimeout(p.ctx, controlTimeout)
	defer cancel()
	if err := p.inspect(ctx); err != nil {
		return err
	}
	attached, err := p.cli.ContainerAttach(ctx, p.identity.ContainerID, client.ContainerAttachOptions{Stream: true, Stdin: true, Stdout: true, Stderr: true, Logs: true})
	if err != nil {
		return err
	}
	if err := p.inspect(ctx); err != nil {
		attached.Close()
		return err
	}
	p.connection = &attached
	p.started = true
	return nil
}

func (p *Attachment) connectionValue() (*client.ContainerAttachResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stopped {
		return nil, os.ErrProcessDone
	}
	if !p.started || p.connection == nil {
		return nil, io.ErrClosedPipe
	}
	return p.connection, nil
}

func (p *Attachment) WriteStdin(data []byte) error {
	attached, err := p.connectionValue()
	if err != nil {
		return err
	}
	n, err := attached.Conn.Write(data)
	if err != nil {
		return err
	}
	if n != len(data) {
		return io.ErrShortWrite
	}
	return nil
}
func (p *Attachment) CloseStdin() error {
	attached, err := p.connectionValue()
	if err != nil {
		return err
	}
	return attached.CloseWrite()
}
func (p *Attachment) Stdout() io.ReadCloser {
	attached, err := p.connectionValue()
	if err != nil {
		return nil
	}
	return &output{attached: attached}
}
func (*Attachment) Stderr() io.ReadCloser { return nil }

type output struct{ attached *client.ContainerAttachResult }

func (r *output) Read(buf []byte) (int, error) { return r.attached.Reader.Read(buf) }
func (r *output) Close() error                 { r.attached.Close(); return nil }

func (p *Attachment) Resize(width, height int) error {
	if err := execapi.ValidatePTYSize(width, height); err != nil {
		return err
	}
	if _, err := p.connectionValue(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(p.ctx), controlTimeout)
	defer cancel()
	if err := p.inspect(ctx); err != nil {
		return err
	}
	_, err := p.cli.ContainerResize(ctx, p.identity.ContainerID, client.ContainerResizeOptions{Width: uint(width), Height: uint(height)})
	return err
}
func (p *Attachment) Signal(signal int) error {
	if _, err := p.connectionValue(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(p.ctx), controlTimeout)
	defer cancel()
	if err := p.inspect(ctx); err != nil {
		return err
	}
	_, err := p.cli.ContainerKill(ctx, p.identity.ContainerID, client.ContainerKillOptions{Signal: fmt.Sprint(signal)})
	return err
}
func (p *Attachment) Wait() error {
	defer p.cancelWait()
	if _, err := p.connectionValue(); err != nil {
		return err
	}
	result := p.cli.ContainerWait(p.ctx, p.identity.ContainerID, client.ContainerWaitOptions{Condition: container.WaitConditionNotRunning})
	select {
	case <-p.ctx.Done():
		return p.ctx.Err()
	case err := <-result.Error:
		return err
	case status := <-result.Result:
		p.mu.Lock()
		p.stopped = true
		p.mu.Unlock()
		if status.Error != nil {
			return errors.New(status.Error.Message)
		}
		if status.StatusCode != 0 {
			return fmt.Errorf("container exited with code %d", status.StatusCode)
		}
		return nil
	}
}
func (p *Attachment) CancelWait() { p.cancelWait() }

// Stop retires an unused handle when Lua releases it before terminal ownership
// transfer. It leaves the admitted container with its lifecycle owner.
func (p *Attachment) Stop() {
	p.cancelWait()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.connection != nil {
		p.connection.Close()
	}
	p.stopped = true
}
