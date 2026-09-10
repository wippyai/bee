//go:build ownerintegration

// SPDX-License-Identifier: MIT

package owner_test

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wippyai/bee/native/client/display"
	"github.com/wippyai/bee/native/client/owner"
	lua "github.com/wippyai/go-lua"
	"github.com/wippyai/runtime/api/attrs"
	ctxapi "github.com/wippyai/runtime/api/context"
	apierror "github.com/wippyai/runtime/api/error"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	"github.com/wippyai/runtime/api/runtime"
	secapi "github.com/wippyai/runtime/api/security"
	ttyapi "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/runtime/lua/engine"
	relaysys "github.com/wippyai/runtime/system/relay"
	ttysys "github.com/wippyai/runtime/system/tty"
)

type testAcceptor struct {
	mu     sync.Mutex
	conns  chan net.Conn
	errs   chan error
	calls  atomic.Int32
	closed atomic.Bool
}

func newTestAcceptor() *testAcceptor {
	return &testAcceptor{
		conns: make(chan net.Conn, 64),
		errs:  make(chan error, 64),
	}
}

func (ta *testAcceptor) Accept(ctx context.Context) (net.Conn, error) {
	ta.calls.Add(1)
	select {
	case conn := <-ta.conns:
		return conn, nil
	case err := <-ta.errs:
		return nil, err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

type testReceiver struct {
	resCh chan yieldResult
}

type yieldResult struct {
	tag  uint64
	data any
	err  error
}

func newTestReceiver() *testReceiver {
	return &testReceiver{resCh: make(chan yieldResult, 1)}
}

func (tr *testReceiver) CompleteYield(tag uint64, data any, err error) {
	tr.resCh <- yieldResult{tag: tag, data: data, err: err}
}

func (tr *testReceiver) wait(t *testing.T, timeout time.Duration) yieldResult {
	t.Helper()
	select {
	case res := <-tr.resCh:
		return res
	case <-time.After(timeout):
		t.Fatal("timeout waiting for CompleteYield")
		return yieldResult{}
	}
}

type testScope struct {
	allowAction   string
	allowResource string
}

func (ts *testScope) With(p secapi.Policy) secapi.Scope   { return ts }
func (ts *testScope) Without(id registry.ID) secapi.Scope { return ts }
func (ts *testScope) Contains(id registry.ID) bool        { return true }
func (ts *testScope) Policies() []secapi.Policy           { return nil }
func (ts *testScope) Evaluate(actor secapi.Actor, action, resource string, meta attrs.Bag) secapi.Result {
	if action == ts.allowAction && resource == ts.allowResource {
		return secapi.Allow
	}
	return secapi.Deny
}

type testInbox struct {
	packages chan *relay.Package
}

func (ti *testInbox) Send(pkg *relay.Package) error {
	select {
	case ti.packages <- pkg:
	default:
	}
	return nil
}

func setupTestContext(t *testing.T, ttyService ttyapi.Service, id string, allowSec bool) (context.Context, ctxapi.FrameContext, *testInbox, pid.PID) {
	t.Helper()
	ctx := ctxapi.NewRootContext()
	if ttyService != nil {
		ctx = ttyapi.WithService(ctx, ttyService)
	}
	node := relaysys.NewNode("node")
	box := &testInbox{packages: make(chan *relay.Package, 32)}
	if err := node.RegisterHost("workers", box); err != nil {
		t.Fatalf("RegisterHost failed: %v", err)
	}
	ctx = relay.WithNode(ctx, node)
	ctx, frame := ctxapi.OpenFrameContext(ctx)
	p := pid.PID{Node: "node", Host: "workers", UniqID: id}
	if err := frame.Set(runtime.FramePIDKey, p); err != nil {
		t.Fatalf("set FramePIDKey failed: %v", err)
	}

	actor := secapi.Actor{ID: "worker-" + id}
	_ = secapi.SetActor(ctx, actor)
	if allowSec {
		scope := &testScope{
			allowAction:   owner.SecurityAction,
			allowResource: owner.SecurityResource,
		}
		_ = secapi.SetScope(ctx, scope)
	} else {
		scope := &testScope{
			allowAction:   "bee.other.action",
			allowResource: "bee.other:resource",
		}
		_ = secapi.SetScope(ctx, scope)
	}

	return ctx, frame, box, p
}

func TestSecurityDeniedBeforeAccept(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = manager.Stop(stopCtx)
	}()

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, _, ownerPID := setupTestContext(t, ttyService, "denied-caller", false)
	defer frame.Close()

	receiver := newTestReceiver()
	cmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)

	err := manager.Handle(ctx, cmd, 1, receiver)
	if err != nil {
		t.Fatalf("Handle returned error: %v", err)
	}

	res := receiver.wait(t, 2*time.Second)
	if res.err == nil {
		t.Fatal("expected PermissionDenied error, got nil")
	}

	var apiErr apierror.Error
	if !errors.As(res.err, &apiErr) || apiErr.Kind() != apierror.PermissionDenied {
		t.Fatalf("expected apierror.PermissionDenied, got %v", res.err)
	}

	if acceptor.calls.Load() != 0 {
		t.Fatalf("acceptor was called %d times, expected 0", acceptor.calls.Load())
	}
}

func TestSecurityAllowedAllowsAccept(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = manager.Stop(stopCtx)
	}()

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, _, ownerPID := setupTestContext(t, ttyService, "allowed-caller", true)
	defer frame.Close()

	srvConn, cliConn := net.Pipe()
	acceptor.conns <- srvConn

	receiver := newTestReceiver()
	cmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)

	err := manager.Handle(ctx, cmd, 1, receiver)
	if err != nil {
		t.Fatalf("Handle returned error: %v", err)
	}

	res := receiver.wait(t, 2*time.Second)
	if res.err != nil {
		t.Fatalf("expected success, got error: %v", res.err)
	}

	att, ok := res.data.(*owner.Attachment)
	if !ok || att == nil {
		t.Fatalf("expected *owner.Attachment, got %T", res.data)
	}

	if att.Grant() == "" {
		t.Fatal("attachment returned empty grant")
	}

	connectCtx, cancelConnect := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelConnect()

	cli, err := display.Connect(connectCtx, cliConn)
	if err != nil {
		t.Fatalf("display.Connect failed: %v", err)
	}
	defer cli.Close()

	if !att.Close() {
		t.Fatal("Close() should return true on first close")
	}
	if att.Close() {
		t.Fatal("Close() should return false on second close")
	}
}

func TestContextOwnerChecks(t *testing.T) {
	l := lua.NewState()
	defer l.Close()

	ownerPID := pid.PID{Node: "node1", Host: "host1", UniqID: "owner-proc"}
	otherPID := pid.PID{Node: "node1", Host: "host1", UniqID: "other-proc"}

	ch := engine.NewChannel(8)
	mgr := owner.New(nil)
	att := owner.NewTestAttachment(mgr, "test-grant-123", ownerPID, 1)
	ud := owner.MakeAttachmentHandleUD(l, ownerPID, 1, "test-grant-123", ch, att)

	// 1. Caller frame matches owner PID: grant() succeeds
	ctxAllowed := ctxapi.NewRootContext()
	ctxAllowed, frameAllowed := ctxapi.OpenFrameContext(ctxAllowed)
	_ = frameAllowed.Set(runtime.FramePIDKey, ownerPID)
	l.SetContext(ctxAllowed)

	l.Push(ud)
	n := owner.CallAttachmentGrant(l)
	if n != 1 {
		t.Fatalf("expected 1 return value, got %d", n)
	}
	val := l.Get(-1)
	l.Pop(1)
	if val.String() != "test-grant-123" {
		t.Fatalf("expected grant 'test-grant-123', got %v", val)
	}

	// 2. Caller frame matches owner PID: channel() succeeds
	l.Push(ud)
	n = owner.CallAttachmentChannel(l)
	if n != 1 {
		t.Fatalf("expected 1 return value, got %d", n)
	}
	chanVal := l.Get(-1)
	l.Pop(1)
	if chanVal.Type() != lua.LTUserData {
		t.Fatalf("expected channel userdata, got %v", chanVal.Type())
	}

	// 3. Caller frame has different PID: grant() fails closed
	ctxDenied := ctxapi.NewRootContext()
	ctxDenied, frameDenied := ctxapi.OpenFrameContext(ctxDenied)
	_ = frameDenied.Set(runtime.FramePIDKey, otherPID)
	l.SetContext(ctxDenied)

	l.Push(ud)
	func() {
		defer func() {
			if r := recover(); r == nil {
				t.Fatal("expected panic / lua error on cross-frame grant access")
			}
		}()
		owner.CallAttachmentGrant(l)
	}()

	// 4. Caller frame has different PID: close() fails closed
	l.Push(ud)
	func() {
		defer func() {
			if r := recover(); r == nil {
				t.Fatal("expected panic / lua error on cross-frame close access")
			}
		}()
		owner.CallAttachmentClose(l)
	}()

	// 5. Caller frame has matching PID: close() succeeds
	l.SetContext(ctxAllowed)
	l.Push(ud)
	n = owner.CallAttachmentClose(l)
	if n != 1 {
		t.Fatalf("expected 1 return value, got %d", n)
	}
	closeVal := l.Get(-1)
	l.Pop(1)
	if closeVal != lua.LTrue {
		t.Fatalf("expected LTrue, got %v", closeVal)
	}
}

func TestCapacityBound32(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = manager.Stop(stopCtx)
	}()

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, _, ownerPID := setupTestContext(t, ttyService, "capacity-test", true)
	defer frame.Close()

	receivers := make([]*testReceiver, 32)
	srvConns := make([]net.Conn, 32)
	cliConns := make([]net.Conn, 32)

	// Fill all 32 connections
	for i := 0; i < 32; i++ {
		receivers[i] = newTestReceiver()
		srvConns[i], cliConns[i] = net.Pipe()
		acceptor.conns <- srvConns[i]

		cmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
		if err := manager.Handle(ctx, cmd, uint64(i+1), receivers[i]); err != nil {
			t.Fatalf("connection %d Handle failed: %v", i, err)
		}
	}

	attachments := make([]*owner.Attachment, 32)
	for i := 0; i < 32; i++ {
		res := receivers[i].wait(t, 3*time.Second)
		if res.err != nil {
			t.Fatalf("connection %d failed: %v", i, res.err)
		}
		attachments[i] = res.data.(*owner.Attachment)
	}

	if manager.ActiveCount() != 32 {
		t.Fatalf("expected 32 active connections, got %d", manager.ActiveCount())
	}

	// 33rd connection attempt must be rejected immediately with RateLimited
	extraReceiver := newTestReceiver()
	extraCmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
	if err := manager.Handle(ctx, extraCmd, 33, extraReceiver); err != nil {
		t.Fatalf("33rd Handle failed: %v", err)
	}

	extraRes := extraReceiver.wait(t, 2*time.Second)
	if extraRes.err == nil {
		t.Fatal("expected 33rd connection to be rejected, but got nil error")
	}
	var apiErr apierror.Error
	if !errors.As(extraRes.err, &apiErr) || apiErr.Kind() != apierror.RateLimited {
		t.Fatalf("expected apierror.RateLimited, got %v", extraRes.err)
	}

	// Close 1 attachment to release slot
	attachments[0].Close()
	// Concurrent accepts do not preserve the connection slice order.
	// Closing an indexed connection here could close a second attachment.

	// Wait for slot cleanup
	deadline := time.Now().Add(2 * time.Second)
	for manager.ActiveCount() != 31 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if manager.ActiveCount() != 31 {
		t.Fatalf("expected 31 active connections after close, got %d", manager.ActiveCount())
	}

	// Now 33rd attempt can succeed
	allowedReceiver := newTestReceiver()
	srvConn33, cliConn33 := net.Pipe()
	defer srvConn33.Close()
	defer cliConn33.Close()
	acceptor.conns <- srvConn33

	if err := manager.Handle(ctx, extraCmd, 34, allowedReceiver); err != nil {
		t.Fatalf("new Handle failed: %v", err)
	}
	allowedRes := allowedReceiver.wait(t, 2*time.Second)
	if allowedRes.err != nil {
		t.Fatalf("expected allowed connection after close, got %v", allowedRes.err)
	}

	// Clean up all remaining
	for i := 0; i < 32; i++ {
		attachments[i].Close()
		srvConns[i].Close()
		cliConns[i].Close()
	}
	allowedRes.data.(*owner.Attachment).Close()

	deadline = time.Now().Add(2 * time.Second)
	for (manager.ActiveCount() != 0 || manager.OwnerCount() != 0) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}

	if manager.ActiveCount() != 0 {
		t.Fatalf("expected 0 active connections after teardown, got %d", manager.ActiveCount())
	}
	if manager.OwnerCount() != 0 {
		t.Fatalf("expected 0 active owners after teardown, got %d", manager.OwnerCount())
	}
}

func TestCancellationDuringAccept(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = manager.Stop(stopCtx)
	}()

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, _, ownerPID := setupTestContext(t, ttyService, "cancel-accept", true)
	defer frame.Close()

	// Create a cancellable context for accept
	acceptCtx, cancelAccept := context.WithCancel(ctx)

	receiver := newTestReceiver()
	cmd := owner.MakeTestAcceptCommand(acceptCtx, ownerPID, 80, 24)

	if err := manager.Handle(ctx, cmd, 1, receiver); err != nil {
		t.Fatalf("Handle failed: %v", err)
	}

	// Wait for Acceptor.Accept to be called and block
	for acceptor.calls.Load() == 0 {
		time.Sleep(5 * time.Millisecond)
	}

	// Cancel while blocking in Accept
	cancelAccept()

	res := receiver.wait(t, 2*time.Second)
	if !errors.Is(res.err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", res.err)
	}

	// Verify pending slot was released
	deadline := time.Now().Add(2 * time.Second)
	for manager.PendingCount() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if manager.PendingCount() != 0 {
		t.Fatalf("expected 0 pending, got %d", manager.PendingCount())
	}
}

func TestClosePreservesProducer(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = manager.Stop(stopCtx)
	}()

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, _, ownerPID := setupTestContext(t, ttyService, "producer-test", true)
	defer frame.Close()

	// 1. Create viewport directly to act as producer
	producerViewport, err := ttyService.Create(ctx, 80, 24)
	if err != nil {
		t.Fatalf("Create producer viewport failed: %v", err)
	}
	producerGrant := producerViewport.Grant()

	// 2. Acceptor creates another attachment for consumer
	srvConn, cliConn := net.Pipe()
	acceptor.conns <- srvConn

	receiver := newTestReceiver()
	cmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
	if err := manager.Handle(ctx, cmd, 1, receiver); err != nil {
		t.Fatalf("Handle failed: %v", err)
	}

	res := receiver.wait(t, 2*time.Second)
	if res.err != nil {
		t.Fatalf("Handle failed: %v", res.err)
	}
	consumerAtt := res.data.(*owner.Attachment)

	// Connect client
	connectCtx, cancelConnect := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelConnect()
	cli, err := display.Connect(connectCtx, cliConn)
	if err != nil {
		t.Fatalf("Connect failed: %v", err)
	}

	// 3. Detach consumer via Close()
	consumerAtt.Close()
	cli.Close()

	// 4. Verify producer viewport is STILL alive and usable
	if err := producerViewport.Resize(100, 30); err != nil {
		t.Fatalf("producer viewport Resize failed after consumer detach: %v", err)
	}

	snap := producerViewport.Snapshot()
	if snap.Width != 100 || snap.Height != 30 {
		t.Fatalf("expected producer resized to 100x30, got %dx%d", snap.Width, snap.Height)
	}

	// Verify producer grant can still produce bindings
	binding, err := ttyService.Binding(producerGrant)
	if err != nil || binding == nil {
		t.Fatalf("producer grant invalid after consumer detach: %v", err)
	}

	_ = producerViewport.Close()
}

func TestManagerStop(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, _, ownerPID := setupTestContext(t, ttyService, "stop-test", true)
	defer frame.Close()

	// Start 2 active attachments
	for i := 0; i < 2; i++ {
		srvConn, cliConn := net.Pipe()
		acceptor.conns <- srvConn

		recv := newTestReceiver()
		cmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
		if err := manager.Handle(ctx, cmd, uint64(i+1), recv); err != nil {
			t.Fatalf("Handle %d failed: %v", i, err)
		}
		res := recv.wait(t, 2*time.Second)
		if res.err != nil {
			t.Fatalf("connection %d failed: %v", i, res.err)
		}

		// Connect client
		connectCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		cli, err := display.Connect(connectCtx, cliConn)
		cancel()
		if err != nil {
			t.Fatalf("display.Connect %d failed: %v", i, err)
		}
		defer cli.Close()
	}

	// Queue 1 pending accept that blocks
	pendingRecv := newTestReceiver()
	pendingCmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
	if err := manager.Handle(ctx, pendingCmd, 3, pendingRecv); err != nil {
		t.Fatalf("pending Handle failed: %v", err)
	}

	// Call manager.Stop
	stopCtx, cancelStop := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelStop()

	if err := manager.Stop(stopCtx); err != nil {
		t.Fatalf("manager.Stop failed: %v", err)
	}

	// Active and pending must now be 0
	if manager.ActiveCount() != 0 {
		t.Fatalf("expected 0 active after stop, got %d", manager.ActiveCount())
	}
	if manager.PendingCount() != 0 {
		t.Fatalf("expected 0 pending after stop, got %d", manager.PendingCount())
	}

	// New accepts must be rejected
	postStopRecv := newTestReceiver()
	postStopCmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
	if err := manager.Handle(ctx, postStopCmd, 4, postStopRecv); err != nil {
		t.Fatalf("post-stop Handle failed: %v", err)
	}
	postStopRes := postStopRecv.wait(t, 2*time.Second)
	if postStopRes.err == nil {
		t.Fatal("expected error for accept after manager.Stop, got nil")
	}
	var apiErr apierror.Error
	if !errors.As(postStopRes.err, &apiErr) || apiErr.Kind() != apierror.Unavailable {
		t.Fatalf("expected apierror.Unavailable, got %v", postStopRes.err)
	}
}

func TestExternalListenerNotClosed(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = manager.Stop(stopCtx)
	}()

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, _, ownerPID := setupTestContext(t, ttyService, "listener-ownership", true)
	defer frame.Close()

	// Perform 3 sequential accepts on the same acceptor
	for i := 0; i < 3; i++ {
		srvConn, cliConn := net.Pipe()
		acceptor.conns <- srvConn

		recv := newTestReceiver()
		cmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
		if err := manager.Handle(ctx, cmd, uint64(i+1), recv); err != nil {
			t.Fatalf("seq %d Handle failed: %v", i, err)
		}
		res := recv.wait(t, 2*time.Second)
		if res.err != nil {
			t.Fatalf("seq %d failed: %v", i, res.err)
		}

		att := res.data.(*owner.Attachment)

		connectCtx, cancelConnect := context.WithTimeout(context.Background(), 2*time.Second)
		cli, err := display.Connect(connectCtx, cliConn)
		cancelConnect()
		if err != nil {
			t.Fatalf("Connect %d failed: %v", i, err)
		}

		att.Close()
		cli.Close()
	}

	// Verify acceptor is still accepting and not closed
	if acceptor.closed.Load() {
		t.Fatal("external acceptor was closed by attachment operations")
	}
	if acceptor.calls.Load() != 3 {
		t.Fatalf("expected 3 acceptor calls, got %d", acceptor.calls.Load())
	}
}

func TestWireProtocolAndErrorMapping(t *testing.T) {
	acceptor := newTestAcceptor()
	manager := owner.New(acceptor)
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = manager.Stop(stopCtx)
	}()

	ttyService := ttysys.NewService()
	defer ttyService.Close()

	ctx, frame, inbox, ownerPID := setupTestContext(t, ttyService, "protocol-err", true)
	defer frame.Close()

	srvConn, cliConn := net.Pipe()
	acceptor.conns <- srvConn

	recv := newTestReceiver()
	cmd := owner.MakeTestAcceptCommand(ctx, ownerPID, 80, 24)
	if err := manager.Handle(ctx, cmd, 1, recv); err != nil {
		t.Fatalf("Handle failed: %v", err)
	}

	res := recv.wait(t, 2*time.Second)
	if res.err != nil {
		t.Fatalf("expected success, got %v", res.err)
	}

	// The host sends first; consume its bounded binary-framed handshake.
	defer cliConn.Close()
	if err := cliConn.SetDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	header := make([]byte, 4)
	if _, err := io.ReadFull(cliConn, header); err != nil {
		t.Fatal(err)
	}
	size := binary.BigEndian.Uint32(header)
	if size > display.MaxPacketSize {
		t.Fatal("oversized host handshake")
	}
	if _, err := io.CopyN(io.Discard, cliConn, int64(size)); err != nil {
		t.Fatal(err)
	}
	badHandshake := []byte(`{"type":"handshake","version":"bee.display.v999"}`)
	packet := make([]byte, 4+len(badHandshake))
	binary.BigEndian.PutUint32(packet, uint32(len(badHandshake)))
	copy(packet[4:], badHandshake)
	if _, err := cliConn.Write(packet); err != nil {
		t.Fatal(err)
	}

	// Wait for event to arrive in inbox
	select {
	case pkg := <-inbox.packages:
		if pkg == nil || len(pkg.Messages) == 0 {
			t.Fatal("empty package received")
		}
		if len(pkg.Messages[0].Payloads) == 0 {
			t.Fatal("empty payloads")
		}
		f, ok := pkg.Messages[0].Payloads[0].Data().(*engine.SubscriptionFrame)
		if !ok || f == nil || len(f.Payloads) == 0 {
			t.Fatalf("expected SubscriptionFrame, got %v", pkg.Messages[0].Payloads[0])
		}
		closed, ok := f.Payloads[0].Data().(owner.Closed)
		if !ok {
			t.Fatalf("expected owner.Closed, got %T", f.Payloads[0].Data())
		}
		if closed.Kind != "closed" {
			t.Fatalf("expected kind 'closed', got %q", closed.Kind)
		}
		if closed.ErrorCode != owner.ErrorCodeProtocolError {
			t.Fatalf("expected error_code %q, got %q", owner.ErrorCodeProtocolError, closed.ErrorCode)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timeout waiting for Closed event in inbox")
	}
}
