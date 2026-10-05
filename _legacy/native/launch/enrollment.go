// SPDX-License-Identifier: MIT

package launch

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/syncthing/notify"
	"go.uber.org/zap"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
	topapi "github.com/wippyai/runtime/api/topology"

	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/boot"
	clusterapi "github.com/wippyai/runtime/api/cluster"
	eventapi "github.com/wippyai/runtime/api/event"
	"github.com/wippyai/runtime/api/logs"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/pid"
	"github.com/wippyai/runtime/api/registry"
)

const (
	// enrollmentEntry is the host-owned registry entry the Hive supervisor
	// reconciles (src/hive/supervisor/enrollment.lua). The owner rewrites it
	// from its trusted and peers directories, so a local client or Hive peer is
	// admitted exactly while its public key file exists.
	enrollmentEntry = "bee.hive.host:enrollment"
	// enrollmentEntryKind must match the entry's declared kind, so the update is
	// a same-kind replacement the registry accepts.
	enrollmentEntryKind = "registry.entry"
	// Live admission belongs to this native owner, not to package history.
	enrollmentOverlayOwner = "bee.launch.enrollment"
)

// enrollmentChangeSet builds the one-entry update that publishes the enrolled
// local client nodes of the trusted directory and the pinned Hive peers.
func enrollmentChangeSet(state string) (registry.ChangeSet, error) {
	clients, err := trustedKeys(ownerTrustedDirectory(state))
	if err != nil {
		return nil, err
	}
	peers, err := trustedKeys(ownerPeersDirectory(state))
	if err != nil {
		return nil, err
	}
	return enrollmentChange(clients, peers), nil
}

// enrollmentChange publishes only validated keys through the owner's overlay.
func enrollmentChange(clients, peers []trustedKey) registry.ChangeSet {
	names := func(keys []trustedKey) []any {
		result := make([]any, 0, len(keys))
		for _, key := range keys {
			result = append(result, key.node)
		}
		return result
	}
	entry := registry.Entry{
		ID:   registry.ParseID(enrollmentEntry),
		Kind: enrollmentEntryKind,
		Data: payload.New(map[string]any{"nodes": names(clients), "peers": names(peers)}),
		Meta: attrs.NewBagFrom(map[string]any{"type": "bee.hive.supervisor_enrollment"}),
	}
	return registry.ChangeSet{{Kind: registry.EntryUpdate, Entry: entry}}
}

// readExecution reads the owner execution persisted by prepareOwner, and
// readMembershipSecret reads the secret the owner's mesh uses.
func readExecution(directory string) (string, error) {
	data, err := os.ReadFile(filepath.Join(directory, executionName))
	if err != nil {
		return "", err
	}
	value := strings.TrimSpace(string(data))
	if len(value) != 32 {
		return "", errors.New("owner execution identity is invalid")
	}
	return value, nil
}

func readMembershipSecret(state string) ([]byte, error) {
	path, err := membershipSecretPath(state)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	secret, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(data)))
	if err != nil || len(secret) != 32 {
		return nil, errors.New("owner membership secret is invalid")
	}
	return secret, nil
}

// trustedKey is one enrolled client node and its validated public key.
type trustedKey struct {
	node string
	key  ed25519.PublicKey
}

// trustedKeys lists the nodes of one key directory in node order, validating
// each key before it is admitted.
func trustedKeys(trusted string) ([]trustedKey, error) {
	entries, err := os.ReadDir(trusted)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	keys := make([]trustedKey, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pub") {
			continue
		}
		node := strings.TrimSuffix(entry.Name(), ".pub")
		if !validTrustedName(node) {
			continue
		}
		public, ok := resolveTrustedKey(trusted, node)
		if !ok {
			continue
		}
		keys = append(keys, trustedKey{node: node, key: public})
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].node < keys[j].node })
	return keys, nil
}

// enrollmentPublisher mirrors the owner's trusted client directory into the
// supervisor's enrollment entry. It depends on the cluster so the update lands
// only while the owner's mesh is up.
func enrollmentPublisher(state string) (boot.Component, error) {
	if !filepath.IsAbs(state) {
		return nil, errors.New("enrollment publisher requires an absolute state directory")
	}
	trusted := ownerTrustedDirectory(state)
	directory := ownerDirectory(state)
	execution, err := readExecution(directory)
	if err != nil {
		return nil, err
	}
	secret, err := readMembershipSecret(state)
	if err != nil {
		return nil, err
	}
	p := &enrollmentPublisherComponent{state: state, directory: directory, trusted: trusted, execution: execution, secret: secret, node: ownerNodeName(state)}
	return boot.New(boot.P{
		Name:      "bee.launch.enrollment",
		DependsOn: []string{"cluster"},
		Start:     p.Start,
		Stop:      p.Stop,
	}), nil
}

// errSupervisorPending defers listing clients until this boot's supervisor has
// registered and its address is published.
var errSupervisorPending = errors.New("the owner supervisor is not published yet")

// publishSupervisor records this boot's Hive supervisor address in the
// rendezvous descriptor, which each boot rewrites without one. A local client
// addresses the supervisor by this address, so the owner lists no client
// before it is published: an eventual name can still carry the owner's
// previous boot on a Hive peer.
func (p *enrollmentPublisherComponent) supervisor(ctx context.Context) (pid.PID, error) {
	pidRegistry := topapi.GetRegistry(ctx)
	if pidRegistry == nil {
		return pid.PID{}, errors.New("enrollment publisher requires the process names")
	}
	supervisor, found, err := topapi.LookupScopedPID(ctx, "bee.hive.supervisor", topapi.Local)
	if err != nil {
		return pid.PID{}, err
	}
	if !found || supervisor.Node != p.node || supervisor.Host != "bee.hive.service:supervisor_host" || supervisor.UniqID == "" {
		return pid.PID{}, errSupervisorPending
	}
	return supervisor, nil
}

func (p *enrollmentPublisherComponent) publishSupervisor(ctx context.Context) error {
	supervisor, err := p.supervisor(ctx)
	if err != nil {
		return err
	}
	store, err := rendezvous.New(filepath.Join(p.state, rendezvous.DirectoryName))
	if err != nil {
		return err
	}
	descriptor, err := store.Read(ctx)
	if err != nil {
		return err
	}
	if descriptor.Supervisor == supervisor.String() {
		return nil
	}
	descriptor.Supervisor = supervisor.String()
	return store.Publish(ctx, descriptor)
}

type enrollmentPublisherComponent struct {
	state              string
	retryInterval      time.Duration
	directory          string
	trusted            string
	execution          string
	node               string
	secret             []byte
	cancel             context.CancelFunc
	done               chan struct{}
	registryClients    []string
	registryPeers      []string
	registryApplied    bool
	registryGeneration uint64
	seededClients      []trustedKey
	seeded             bool
}

// seedEnrollment initializes the owner's local enrollment from its membership
// secret and makes its peers exactly the given client keys, so a joining
// client's mesh handshake resolves and a departed client's no longer does.
func (p *enrollmentPublisherComponent) seedEnrollment(ctx context.Context, enrollment *rendezvous.Enrollment, keys []trustedKey) error {
	if err := enrollment.Initialize(ctx, p.execution, p.secret); err != nil {
		return err
	}
	current, err := enrollment.Read(ctx, p.execution)
	if err != nil {
		return err
	}
	wanted := make(map[string]bool, len(keys))
	for _, key := range keys {
		wanted[key.node] = true
	}
	for _, node := range current.Peers() {
		if wanted[node] {
			continue
		}
		key, _ := current.PeerKey(node)
		if err := enrollment.Remove(ctx, p.execution, node, key); err != nil {
			return err
		}
	}
	for _, key := range keys {
		if _, err := enrollment.Register(ctx, p.execution, key.node, key.key); err != nil {
			return err
		}
	}
	return nil
}

// retireDepartedClients removes the trusted key of every client that no longer
// holds its liveness lock. Holding the lock proves the client process is
// alive; the OS releases it when the process ends, however it ends.
func retireDepartedClients(ctx context.Context, trusted string) error {
	entries, err := os.ReadDir(trusted)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pub") {
			continue
		}
		node := strings.TrimSuffix(entry.Name(), ".pub")
		if !validTrustedName(node) {
			continue
		}
		unlock, err := privatefile.TryLock(ctx, trusted, clientLockName(node))
		if errors.Is(err, privatefile.ErrLockBusy) {
			continue
		}
		if err != nil {
			return err
		}
		removed := os.Remove(filepath.Join(trusted, entry.Name()))
		if err := errors.Join(removed, unlock()); err != nil {
			return err
		}
	}
	return nil
}

// publish mirrors one snapshot of the trusted directory. A client waits on the
// local enrollment and then sends its first request to the published
// supervisor, and the supervisor admits from the host entry, so the entry is
// written first, the supervisor address is published next, and the local
// enrollment lists only the nodes that write named.
func (p *enrollmentPublisherComponent) publish(ctx context.Context, reg registry.Registry, enrollment *rendezvous.Enrollment) error {
	log := logs.GetLogger(ctx).Named("bee.launch.enrollment")
	phase := func(name, stage string) {
		log.Info("Boot phase", zap.String("phase", name), zap.String("stage", stage))
	}
	// The service's name is the existing readiness barrier: before it runs the
	// deployment's initial LoadState can still clear process-local overlays.
	if _, err := p.supervisor(ctx); err != nil {
		return err
	}
	phase("enrollment_snapshot", "begin")
	if err := retireDepartedClients(ctx, p.trusted); err != nil {
		return err
	}
	keys, err := trustedKeys(p.trusted)
	if err != nil {
		return err
	}
	peers, err := trustedKeys(ownerPeersDirectory(p.state))
	if err != nil {
		return err
	}
	clientNames, peerNames := trustedNames(keys), trustedNames(peers)
	phase("enrollment_snapshot", "end")
	if !p.registryApplied || !slices.Equal(clientNames, p.registryClients) || !slices.Equal(peerNames, p.registryPeers) {
		writer, ok := reg.(registry.OverlayWriter)
		if !ok {
			return errors.New("enrollment publisher requires registry overlays")
		}
		changes := enrollmentChange(keys, peers)
		if !p.registryApplied {
			entries, generation, err := writer.GetOverlay(enrollmentOverlayOwner)
			if err != nil {
				return err
			}
			p.registryGeneration = generation
			if len(entries) == 0 {
				changes[0].Kind = registry.EntryCreate
			} else if len(entries) != 1 || entries[0].ID.String() != enrollmentEntry {
				return errors.New("unexpected enrollment overlay contents")
			}
		}
		phase("enrollment_overlay", "begin")
		generation, err := writer.ApplyOverlay(ctx, enrollmentOverlayOwner, p.registryGeneration, changes)
		if err != nil {
			phase("enrollment_overlay", "failed")
			return err
		}
		phase("enrollment_overlay", "end")
		p.registryGeneration = generation
		p.registryClients, p.registryPeers, p.registryApplied = clientNames, peerNames, true
	}
	if err := p.publishSupervisor(ctx); err != nil {
		return err
	}
	if !p.seeded || !sameTrustedKeys(p.seededClients, keys) {
		phase("enrollment_seed", "begin")
		if err := p.seedEnrollment(ctx, enrollment, keys); err != nil {
			phase("enrollment_seed", "failed")
			return err
		}
		phase("enrollment_seed", "end")
		p.seededClients, p.seeded = cloneTrustedKeys(keys), true
	}
	return nil
}

func trustedNames(keys []trustedKey) []string {
	names := make([]string, 0, len(keys))
	for _, key := range keys {
		names = append(names, key.node)
	}
	return names
}

func sameTrustedKeys(left, right []trustedKey) bool {
	if len(left) != len(right) {
		return false
	}
	for index, key := range left {
		if key.node != right[index].node || !bytes.Equal(key.key, right[index].key) {
			return false
		}
	}
	return true
}

func cloneTrustedKeys(keys []trustedKey) []trustedKey {
	cloned := make([]trustedKey, len(keys))
	for index, key := range keys {
		cloned[index] = trustedKey{node: key.node, key: append(ed25519.PublicKey(nil), key.key...)}
	}
	return cloned
}

func watchEnrollmentDirectories(ctx context.Context, directories ...string) (<-chan struct{}, <-chan struct{}, error) {
	changed := make(chan struct{}, 1)
	channels := make([]chan notify.EventInfo, 0, len(directories))
	for _, directory := range directories {
		events := make(chan notify.EventInfo, 64)
		path := filepath.Clean(directory) + string(os.PathSeparator)
		if err := notify.Watch(path, events, notify.All); err != nil {
			for _, channel := range channels {
				notify.Stop(channel)
			}
			return nil, nil, err
		}
		channels = append(channels, events)
	}
	done := make(chan struct{})
	var wait sync.WaitGroup
	for _, events := range channels {
		wait.Add(1)
		go func(events chan notify.EventInfo) {
			defer wait.Done()
			defer notify.Stop(events)
			for {
				select {
				case <-ctx.Done():
					return
				case change, ok := <-events:
					if !ok || change == nil || !strings.HasSuffix(filepath.Base(change.Path()), ".pub") {
						continue
					}
					select {
					case changed <- struct{}{}:
					default:
					}
				}
			}
		}(events)
	}
	go func() {
		wait.Wait()
		close(done)
	}()
	return changed, done, nil
}

func subscribeEnrollmentEvent(lifetime, ctx context.Context, system eventapi.System, kind eventapi.Kind) (<-chan struct{}, <-chan struct{}, error) {
	wakeups := make(chan struct{}, 1)
	done := make(chan struct{})
	bus := eventapi.GetBus(ctx)
	if bus == nil {
		return nil, nil, errors.New("enrollment publisher requires the event bus")
	}
	events := make(chan eventapi.Event, 16)
	subscriber, err := bus.SubscribeP(lifetime, system, kind, events)
	if err != nil {
		return nil, nil, err
	}
	go func() {
		defer close(done)
		defer bus.Unsubscribe(context.WithoutCancel(lifetime), subscriber)
		for {
			select {
			case <-lifetime.Done():
				return
			case _, ok := <-events:
				if !ok {
					return
				}
				select {
				case wakeups <- struct{}{}:
				default:
				}
			}
		}
	}()
	return wakeups, done, nil
}

// Start arms the publisher and returns. Publication waits for the supervisor's
// existing readiness name, after deployment loading. Each refresh publishes
// one process-local snapshot; until it succeeds no client is listed locally.
func (p *enrollmentPublisherComponent) Start(ctx context.Context) error {
	reg := registry.GetRegistry(ctx)
	if reg == nil {
		return errors.New("enrollment publisher requires the registry")
	}
	if _, ok := reg.(registry.OverlayWriter); !ok {
		return errors.New("enrollment publisher requires registry overlays")
	}
	log := logs.GetLogger(ctx).Named("bee.launch.enrollment")
	enrollment, err := rendezvous.NewEnrollment(p.directory)
	if err != nil {
		return err
	}
	lifetime, cancel := context.WithCancel(context.WithoutCancel(ctx))
	p.cancel = cancel
	changes, changesDone, err := watchEnrollmentDirectories(lifetime, p.trusted, ownerPeersDirectory(p.state))
	if err != nil {
		cancel()
		p.cancel = nil
		return fmt.Errorf("watch enrollment directories: %w", err)
	}
	readiness, readinessDone, err := subscribeEnrollmentEvent(lifetime, ctx, "bee.launch", "supervisor.ready")
	if err != nil {
		cancel()
		<-changesDone
		p.cancel = nil
		return fmt.Errorf("watch supervisor readiness: %w", err)
	}
	departures, departuresDone, err := subscribeEnrollmentEvent(lifetime, ctx, clusterapi.System, clusterapi.NodeLeft)
	if err != nil {
		cancel()
		<-changesDone
		<-readinessDone
		p.cancel = nil
		return fmt.Errorf("watch client departures: %w", err)
	}
	p.done = make(chan struct{})
	go func() {
		defer close(p.done)
		defer func() {
			<-changesDone
			<-departuresDone
			<-readinessDone
		}()
		interval := p.retryInterval
		if interval == 0 {
			interval = time.Second
		}
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		published := false
		// A refused publication is retried on the ticker until one succeeds,
		// so a change that arrives while the registry is busy is not lost.
		publish := func() {
			if err := p.publish(lifetime, reg, enrollment); err != nil {
				// Before the first publish the entry is still being applied.
				if published {
					log.Warn("enrollment publication failed", zap.Error(err))
				} else {
					log.Debug("enrollment entry not yet writable", zap.Error(err))
				}
				ticker.Reset(interval)
			} else {
				published = true
				ticker.Stop()
			}
		}
		publish()
		for {
			select {
			case <-lifetime.Done():
				return
			case <-changes:
				publish()
			case <-departures:
				publish()
			case <-readiness:
				publish()
			case <-ticker.C:
				publish()
			}
		}
	}()
	return nil
}

func (p *enrollmentPublisherComponent) Stop(context.Context) error {
	if p.cancel != nil {
		p.cancel()
		<-p.done
		p.cancel = nil
		p.done = nil
	}
	return nil
}
