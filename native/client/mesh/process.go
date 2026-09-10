//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	"github.com/wippyai/runtime/api/runtime"
	"sync"
	"sync/atomic"
)

var ErrActorEnded = errors.New("mesh client: actor ended")
var ErrInboxFull = errors.New("mesh client: admission inbox full")

type actorFactory struct {
	proc *nativeActor
	used atomic.Bool
}

func (f *actorFactory) Create(id registry.ID) (process.Process, *process.Meta, error) {
	if id.String() != actorSource || !f.used.CompareAndSwap(false, true) {
		return nil, nil, errors.New("mesh client: unapproved native process")
	}
	return f.proc, nil, nil
}

type nativeActor struct {
	actor  *Actor
	ready  chan context.Context
	cancel context.CancelCauseFunc
	mu     sync.Mutex
	err    error
}

func (p *nativeActor) Init(ctx context.Context, _ string, _ payload.Payloads) error {
	ctx, p.cancel = context.WithCancelCause(ctx)
	p.actor.ctx = ctx
	frame := ctxapi.FrameFromContext(ctx)
	if frame == nil {
		return errors.New("mesh client: process frame missing")
	}
	frame.Seal()
	p.ready <- ctx
	return nil
}
func (p *nativeActor) Step(events []process.Event, out *process.StepOutput) error {
	// Drain transfers every package to this process. Release the entire batch,
	// including unvisited events when inbox overflow ends the step early.
	defer func() {
		for _, event := range events {
			if event.Type == process.EventMessage {
				if pkg, ok := event.Data.(*relay.Package); ok {
					relay.ReleasePackage(pkg)
				}
			}
		}
	}()

	for _, event := range events {
		if event.Type != process.EventMessage {
			continue
		}
		pkg, ok := event.Data.(*relay.Package)
		if !ok || pkg == nil {
			continue
		}
		// Application control replies must come from the enrolled owner node.
		// Remote admission requires runtime source-provenance enforcement (a release
		// gate); checking this field here cannot establish transport provenance.
		// Exact supervisor/process identity remains the operation decoder's job.
		if pkg.Source.Node != p.actor.owner {
			continue
		}
		for _, message := range pkg.Messages {
			if message == nil || len(message.Payloads) != 1 {
				continue
			}
			body, ok := controlBody(message.Payloads[0])
			if !ok || !validBody(message.Topic, body) {
				continue
			}
			owned := Message{From: pkg.Source, Topic: message.Topic, Body: bytes.Clone(body)}
			select {
			case p.actor.inbox <- owned:
			default:
				return ErrInboxFull
			}
		}
	}
	out.Idle()
	return nil
}
func (p *nativeActor) Close() {
	if p.cancel != nil {
		p.cancel(ErrActorEnded)
	}
}
func (p *nativeActor) OnStart(context.Context, pid.PID, process.Process) error { return nil }
func (p *nativeActor) OnComplete(_ context.Context, _ pid.PID, result *runtime.Result) {
	err := ErrActorEnded
	if result != nil && result.Error != nil {
		err = fmt.Errorf("mesh client actor: %w", result.Error)
	}
	p.mu.Lock()
	p.err = err
	p.mu.Unlock()
	p.cancel(err)
}
