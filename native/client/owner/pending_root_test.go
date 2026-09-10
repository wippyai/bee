//go:build ownerintegration

// SPDX-License-Identifier: MIT
package owner_test

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/owner"
	ttysys "github.com/wippyai/runtime/system/tty"
)

type finishingAcceptor struct{ entered, canceled, release chan struct{} }

func (a *finishingAcceptor) Accept(ctx context.Context) (net.Conn, error) {
	close(a.entered)
	<-ctx.Done()
	close(a.canceled)
	<-a.release
	return nil, ctx.Err()
}
func TestStopJoinsPendingAcceptCleanup(t *testing.T) {
	acceptor := &finishingAcceptor{make(chan struct{}), make(chan struct{}), make(chan struct{})}
	manager := owner.New(acceptor)
	service := ttysys.NewService()
	defer service.Close()
	ctx, frame, _, id := setupTestContext(t, service, "pending-cleanup", true)
	defer frame.Close()
	receiver := newTestReceiver()
	if err := manager.Handle(ctx, owner.MakeTestAcceptCommand(ctx, id, 80, 24), 1, receiver); err != nil {
		t.Fatal(err)
	}
	<-acceptor.entered
	done := make(chan error, 1)
	go func() { done <- manager.Stop(context.Background()) }()
	<-acceptor.canceled
	select {
	case <-done:
		close(acceptor.release)
		t.Fatal("Stop returned before pending accept released ownership")
	case <-time.After(20 * time.Millisecond):
	}
	close(acceptor.release)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not join completed accept")
	}
}
