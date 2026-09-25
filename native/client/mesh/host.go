//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"context"
	"errors"
	ctxapi "github.com/wippyai/runtime/api/context"
	"github.com/wippyai/runtime/api/process"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/api/relay"
	"github.com/wippyai/runtime/api/runtime"
	"github.com/wippyai/runtime/api/security"
	hostapi "github.com/wippyai/runtime/api/service/host"
	topapi "github.com/wippyai/runtime/api/topology"
	ttyapi "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/boot/components/core"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
	hostsvc "github.com/wippyai/runtime/service/host"
	processsys "github.com/wippyai/runtime/system/process"
	"github.com/wippyai/runtime/system/scheduler"
	actorengine "github.com/wippyai/runtime/system/scheduler/actor"
	securitysys "github.com/wippyai/runtime/system/security"
	topologysys "github.com/wippyai/runtime/system/topology"
	ttysys "github.com/wippyai/runtime/system/tty"
	"go.uber.org/zap"
)

// ActorHost is the host of the physical client's actor. The owner's desktop
// bridge admits native desktop calls only from this host.
const ActorHost = "bee.hive_host.desktop:display_host"
const actorSource = "bee.client:physical"

// WithActor uses the standard process host, PID generator and topology lifecycle.
// run receives the real process frame and must stop on context cancellation.
// It must finish viewport work before returning. No Lua engine, registry store,
// workspace store or alternate transport is loaded here. Remote monitor ingress
// remains a runtime integration gate; local topology registration is implemented.
func WithActor(ctx context.Context, stack *stackpkg.Stack, owner string, run func(context.Context, *Actor) error) (result error) {
	if ctx == nil || stack == nil || stack.Node == nil || stack.Router == nil || owner == "" || run == nil {
		return errors.New("mesh client: invalid actor assembly")
	}
	root := ctxapi.WithAppContext(ctx, ctxapi.NewAppContext())
	root = relay.WithNode(root, stack.Node)
	root = relay.WithRouter(root, stack.Router)
	var err error
	root, err = core.PIDGen().Load(root)
	if err != nil {
		return err
	}
	topology := topologysys.NewTopology(stack.Router, stack.Node.ID())
	pidRegistry := topologysys.NewPIDRegistry()
	root = topapi.WithTopology(root, topology)
	root = topapi.WithRegistry(root, pidRegistry)
	if names := topapi.GetEventualRegistry(ctx); names != nil {
		root = topapi.WithEventualRegistry(root, names)
		pidRegistry.SetEventualRegistry(names)
	}
	tty := ttysys.NewService()
	defer func() { result = errors.Join(result, tty.Close()) }()
	transport, err := internode.NewSurfaceTransport(stack.ConnMgr, stack.Membership)
	if err != nil {
		return err
	}
	if err := tty.SetMesh(stack.Node.ID(), transport); err != nil {
		return err
	}
	root = ttyapi.WithService(root, tty)
	lifecycle := processsys.NewLifecycleRegistry()
	lifecycle.Register("topology", topologysys.NewLifecycle(topology, pidRegistry, zap.NewNop()))
	ready := make(chan context.Context, 1)
	proc := &nativeActor{ready: ready, actor: &Actor{owner: owner, router: stack.Router, inbox: make(chan Message, maxMessages)}}
	engine := actorengine.NewScheduler(scheduler.NewRegistry(), actorengine.WithWorkers(1), actorengine.WithMaxProcesses(1), actorengine.WithLifecycle(lifecycle))
	host := hostsvc.NewHost(registry.ParseID(ActorHost), &hostapi.EntryConfig{}, engine, &actorFactory{proc: proc}, process.GetPIDGenerator(root), zap.NewNop(), hostsvc.WithPIDRegistry(pidRegistry))
	// Capture completion before releasing the process frame. Cancellation tells
	// the physical loop to retire; released frame references fail closed in Wippy.
	lifecycle.Register("client", proc)
	lifecycle.Register("tty", tty)
	lifecycle.Register("frame", host)
	if err := stack.Node.RegisterHost(ActorHost, host); err != nil {
		return err
	}
	defer stack.Node.UnregisterHost(ActorHost)
	if _, err := host.Start(root); err != nil {
		return err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
		defer cancel()
		result = errors.Join(result, host.Stop(cleanup))
	}()
	generated, err := host.Run(root, &process.Start{Source: registry.ParseID(actorSource), Context: []ctxapi.Pair{
		security.ActorPair(security.Actor{ID: "bee-client/" + stack.Node.ID()}),
		security.ScopePair(securitysys.NewScope(nil)),
	}})
	if err != nil {
		return err
	}
	frame := <-ready // Init completed synchronously before host.Run returned.
	proc.actor.id = generated
	// Init exposes the original runtime frame without inventing or copying a PID.
	actual, ok := runtime.GetFramePID(frame)
	if !ok || !samePID(actual, generated) {
		return errors.New("mesh client: runtime frame identity mismatch")
	}
	result = run(frame, proc.actor)
	proc.mu.Lock()
	terminalErr := proc.err
	proc.mu.Unlock()
	return errors.Join(result, terminalErr)
}
