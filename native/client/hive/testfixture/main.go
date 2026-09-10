//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
// Separate compiled client-role acceptance process. Uses explicit disposable
// fixture enrollment, not public startup or a same-account admission shortcut.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/mesh"
	"github.com/wippyai/bee/native/client/physical"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	ctxapi "github.com/wippyai/runtime/api/context"
	eventapi "github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/relay"
	metricscfg "github.com/wippyai/runtime/api/service/metrics"
	topapi "github.com/wippyai/runtime/api/topology"
	tty "github.com/wippyai/runtime/api/tty"
	bootsys "github.com/wippyai/runtime/boot/components/system"
	stackpkg "github.com/wippyai/runtime/cluster"
	"github.com/wippyai/runtime/cluster/internode"
	"github.com/wippyai/runtime/service/metrics"
	"github.com/wippyai/runtime/system/eventbus"
	"github.com/wippyai/runtime/system/payload"
	topologysys "github.com/wippyai/runtime/system/topology"
	"go.uber.org/zap"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() (result error) {
	var cfg struct {
		Cluster struct {
			Name       string `json:"name"`
			Membership struct {
				BindAddr      string `json:"bind_addr"`
				AdvertiseAddr string `json:"advertise_addr"`
				BindPort      int    `json:"bind_port"`
				Secret        string `json:"secret_key"`
				Seed          string `json:"join_addrs"`
			} `json:"membership"`
			Internode struct {
				BindAddr string                     `json:"bind_addr"`
				BindPort int                        `json:"bind_port"`
				Identity string                     `json:"identity_key"`
				Trusted  map[string]string          `json:"trusted_peer_keys"`
				TLS      internode.ManagerTLSConfig `json:"tls"`
			} `json:"internode"`
		} `json:"cluster"`
	}
	raw, err := os.ReadFile(".wippy.yaml")
	if err != nil {
		return err
	}
	if err = json.Unmarshal(raw, &cfg); err != nil {
		return err
	}
	if cfg.Cluster.Name != "node-1" && cfg.Cluster.Name != "node-2" {
		return errors.New("fixture requires an explicitly enrolled client node name")
	}
	const loopback = "127.0.0.1"
	membershipBind := cfg.Cluster.Membership.BindAddr
	if membershipBind == "" {
		membershipBind = loopback
	}
	membershipAdvertise := cfg.Cluster.Membership.AdvertiseAddr
	if membershipAdvertise == "" {
		membershipAdvertise = loopback
	}
	internodeBind := cfg.Cluster.Internode.BindAddr
	if internodeBind == "" {
		internodeBind = loopback
	}
	membershipPort := cfg.Cluster.Membership.BindPort
	internodePort := cfg.Cluster.Internode.BindPort
	// The parent test alone writes these credentials in a private disposable root.
	collector := metrics.NewCollector(metricscfg.Config{})
	defer collector.Close()
	bus := eventbus.NewBus()
	logger := zap.NewNop()
	if os.Getenv("BEE_NATIVE_DESKTOP_DIAGNOSTICS") == "1" {
		logger, err = zap.NewDevelopment()
		if err != nil {
			return err
		}
	}
	stack, err := stackpkg.AssembleStack(stackpkg.StackConfig{NodeName: cfg.Cluster.Name, Logger: logger, Bus: bus, Collector: collector, Transcoder: payload.NewTranscoder(), MembershipBindAddr: membershipBind, MembershipAdvertise: membershipAdvertise, MembershipBindPort: membershipPort, InternodeBindAddr: internodeBind, InternodeBindPort: internodePort, SecretKey: cfg.Cluster.Membership.Secret, InternodeIdentityKey: cfg.Cluster.Internode.Identity, InternodeTrustedPeerKeys: cfg.Cluster.Internode.Trusted, InternodeTLS: cfg.Cluster.Internode.TLS, JoinAddrs: []string{cfg.Cluster.Membership.Seed}, Meta: clusterapi.NodeMeta{"raft_eligible": "false", internode.MetadataSurfaceProtocol: "1"}})
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, stack.Stop()) }()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	root := ctxapi.WithAppContext(ctx, ctxapi.NewAppContext())
	root = clusterapi.WithMembership(root, stack.Membership)
	root = eventapi.WithBus(root, bus)
	root = relay.WithNode(root, stack.Node)
	root = relay.WithRouter(root, stack.Router)
	root = topapi.WithRegistry(root, topologysys.NewPIDRegistry())
	names := bootsys.EventualReg()
	root, err = names.Load(root)
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, names.(boot.Stopper).Stop(context.WithoutCancel(root))) }()
	if err = stack.Start(root); err != nil {
		return err
	}
	if err = names.(boot.Starter).Start(root); err != nil {
		return err
	}
	if os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL") == "1" {
		return mesh.WithActor(root, stack, "node-0", physicalProbe)
	}
	fmt.Println("BEE_HIVE_SUPERVISOR ready native-client")
	input := bufio.NewScanner(os.Stdin)
	for input.Scan() {
		switch input.Text() {
		case "probe":
			if err := mesh.WithActor(root, stack, "node-0", probe); err != nil {
				return err
			}
			fmt.Println("BEE_HIVE_SUPERVISOR probe_passed")
		case "stop":
			fmt.Println("BEE_HIVE_SUPERVISOR stopped")
			return nil
		default:
			return errors.New("unsupported native fixture command")
		}
	}
	return input.Err()
}
func awaitSupervisor(ctx context.Context, actor *mesh.Actor) error {
	for attempt := 0; ; attempt++ {
		if _, err := actor.OwnerSupervisor(ctx); err == nil {
			break
		}
		if attempt >= 300 {
			return errors.New("native client could not discover owner")
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
	return nil
}
func probe(ctx context.Context, actor *mesh.Actor) error {
	if err := awaitSupervisor(ctx, actor); err != nil {
		return err
	}
	client, err := hive.NewDesktop(ctx, actor, "node-0", strings.Repeat("a", 32))
	if err != nil {
		return err
	}
	catalog, err := client.List(ctx, "native-list")
	if err != nil {
		return err
	}
	if len(catalog.Workspaces) != 1 || len(catalog.Workspaces[0].Desktops) != 1 {
		return errors.New("unexpected owner catalog")
	}
	workspace := catalog.Workspaces[0]
	service := tty.GetService(ctx)
	if service == nil {
		return errors.New("missing native viewport service")
	}
	for i := 0; i < 2; i++ {
		mounted, err := client.Attach(ctx, fmt.Sprintf("native-attach-%d", i), workspace.ID, workspace.Desktops[0].ID, hive.Control)
		if err != nil {
			return err
		}
		view, err := service.Attach(ctx, mounted.Mount)
		if err != nil {
			return err
		}
		if err = waitText(ctx, view, "$ "); err != nil {
			view.Close()
			return err
		}
		command := "native_shell=retained; printf 'NATIVE_%s_OK\\n' \"$native_shell\""
		if i == 1 {
			command = "printf 'NATIVE_REJOIN_%s_OK\\n' \"$native_shell\""
		}
		if err = view.Send(tty.Event{Type: "paste", Paste: command}); err != nil {
			view.Close()
			return err
		}
		if err = view.Send(tty.Event{Type: "key", KeyType: "enter", Action: "press"}); err != nil {
			view.Close()
			return err
		}
		needle := "NATIVE_retained_OK"
		if i == 1 {
			needle = "NATIVE_REJOIN_retained_OK"
		}
		if err = waitText(ctx, view, needle); err != nil {
			view.Close()
			return err
		}
		if err = client.Detach(ctx, fmt.Sprintf("native-detach-%d", i), mounted); err != nil {
			view.Close()
			return err
		}
		if err = view.Send(tty.Event{Type: "paste", Paste: "forbidden"}); err == nil {
			view.Close()
			return errors.New("stale native mount accepted input")
		}
		if err = view.Close(); err != nil {
			return err
		}
	}
	return nil
}
func waitText(ctx context.Context, view tty.Viewport, needle string) error {
	timeout := time.NewTimer(5 * time.Second)
	defer timeout.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		if strings.Contains(strings.Join(view.Snapshot().Rows, "\n"), needle) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timeout.C:
			return fmt.Errorf("native viewport missing %s", needle)
		case <-tick.C:
		}
	}
}

func physicalProbe(ctx context.Context, actor *mesh.Actor) error {
	diagnosticPhase("discover")
	if err := awaitSupervisor(ctx, actor); err != nil {
		return err
	}
	diagnosticPhase("supervisor-found")
	client, err := hive.NewDesktop(ctx, actor, "node-0", strings.Repeat("a", 32))
	if err != nil {
		return err
	}
	catalog, err := client.List(ctx, "physical-list")
	if err != nil {
		return err
	}
	if len(catalog.Workspaces) != 1 || len(catalog.Workspaces[0].Desktops) != 1 {
		return errors.New("unexpected physical catalog")
	}
	diagnosticPhase("catalog-received")
	workspace := catalog.Workspaces[0]
	// A fresh OS client must never reuse a mutation key from a prior process;
	// the owner may retain that receipt after retiring the old attachment.
	keyPrefix := fmt.Sprintf("physical-%d-%d", os.Getpid(), time.Now().UnixNano())
	// This crash proof allows the existing 40-second node-departure window;
	// it does not claim prompt exact-actor exit notification.
	mode := hive.Control
	if os.Getenv("BEE_NATIVE_DESKTOP_OBSERVER") == "1" {
		mode = hive.Observe
	}
	var mounted hive.DesktopMount
	for attempt := 0; ; attempt++ {
		mounted, err = client.Attach(ctx, fmt.Sprintf("%s-attach-%d", keyPrefix, attempt), workspace.ID, workspace.Desktops[0].ID, mode)
		if err == nil || os.Getenv("BEE_NATIVE_DESKTOP_PHYSICAL_CRASH") != "1" || attempt >= 159 {
			break
		}
		// Keep one mesh incarnation while the old controller is retired. Only
		// definitive refusals permit a new mutation key; never retry uncertainty.
		var rejected *hive.Rejected
		if !errors.As(err, &rejected) || !retryableCrashRefusal(rejected) {
			break
		}
		diagnosticPhase("attachment-refused-awaiting-cleanup")
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}
	if err != nil {
		return fmt.Errorf("physical attach: %w", err)
	}
	diagnosticPhase("attachment-admitted")
	service := tty.GetService(ctx)
	if service == nil {
		return errors.New("missing physical viewport service")
	}
	view, err := service.Attach(ctx, mounted.Mount)
	if err != nil {
		return fmt.Errorf("physical viewport attach: %w", err)
	}
	diagnosticPhase("viewport-attached")
	remote, ok := view.(physical.Viewport)
	if !ok {
		view.Close()
		return errors.New("physical mount lacks checked native interface")
	}
	rights := tty.MountRights{Observe: true, Input: mode == hive.Control, Resize: mode == hive.Control}
	if mode == hive.Observe {
		if remote.Check(ctx, tty.RightInput) == nil || remote.Check(ctx, tty.RightResize) == nil {
			view.Close()
			return errors.New("observer acquired input or resize authority")
		}
	}
	display, cancel := context.WithDeadline(ctx, mounted.Expires)
	defer cancel()
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		select {
		case <-display.Done():
		case <-mounted.Done():
			cancel()
		}
	}()
	diagnosticPhase("physical-run")
	err = physical.Run(display, remote, rights, os.Stdin, os.Stdout)
	cancel()
	<-stopped
	if err != nil {
		return fmt.Errorf("physical run: %w", err)
	}
	diagnosticPhase("physical-stopped")
	return client.Detach(ctx, keyPrefix+"-detach", mounted)
}

func diagnosticPhase(phase string) {
	if os.Getenv("BEE_NATIVE_DESKTOP_DIAGNOSTICS") == "1" {
		fmt.Fprintln(os.Stderr, "BEE_CLIENT_PHASE", phase)
	}
}

// Fixture-only retry policy for explicit negative attachment receipts.
func retryableCrashRefusal(err *hive.Rejected) bool {
	if err.Fault.Code == "DESKTOP_CONTROLLED" {
		return true
	}
	if err.Fault.Code == "BUSY" {
		return err.Fault.Message == "Desktop request already pending" || err.Fault.Message == "Desktop already has a controller"
	}
	if err.Fault.Code != "UNAVAILABLE" {
		return false
	}
	switch err.Fault.Message {
	case "Desktop is starting", "Desktop already has a controller", "Previous connection is being revoked", "Desktop session is closing":
		return true
	}
	return false
}
