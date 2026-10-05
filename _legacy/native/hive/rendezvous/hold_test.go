//go:build rendezvousintegration

// SPDX-License-Identifier: MIT

package rendezvous

import (
	"context"
	"errors"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	app "github.com/wippyai/runtime/cmd/app"
)

// holdState takes the application's real state lock for one test by driving the
// model's own runner through a host that blocks in the lock-held preparation
// phase. It returns the release.
func holdState(t *testing.T, state string) (func() error, error) {
	t.Helper()
	started := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	executable := app.Executable{Name: "state-holder", Command: "holder", Host: blockingHost{started: started}}
	go func() { done <- app.Run(ctx, executable, []string{"--state", state, "run"}) }()
	select {
	case <-started:
	case err := <-done:
		cancel()
		return nil, err
	}
	return func() error {
		cancel()
		if err := <-done; err != nil && !errors.Is(err, context.Canceled) {
			return err
		}
		return nil
	}, nil
}

type blockingHost struct{ started chan struct{} }

func (h blockingHost) Plan(context.Context, app.Launch) (app.Plan, error) {
	return app.Plan{Prepare: func(ctx context.Context) (boot.Config, func() error, error) {
		close(h.started)
		<-ctx.Done()
		return nil, nil, ctx.Err()
	}}, nil
}
