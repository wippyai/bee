// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"go.uber.org/zap"

	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
	topapi "github.com/wippyai/runtime/api/topology"

	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/logs"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/registry"
)

const (
	// enrollmentEntry is the host-owned registry entry the Hive supervisor
	// reconciles (src/hive/supervisor/enrollment.lua). The owner rewrites it
	// from its trusted and peers directories, so a local client or Hive peer is
	// admitted exactly while its public key file exists.
	enrollmentEntry = "bee.hive.supervisor:enrollment_nodes"
	// enrollmentEntryKind must match the entry's declared kind, so the update is
	// a same-kind replacement the registry accepts.
	enrollmentEntryKind = "registry.entry"
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

// enrollmentChange follows the runtime's own host-entry write path
// (cmd/internal/entries/loader.go ApplyToRegistry -> Registry.Apply with an
// EntryUpdate operation); only validated keys are named.
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
// readMembershipSecret reads the owner's membership secret.
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

func readMembershipSecret(directory string) ([]byte, error) {
	data, err := os.ReadFile(filepath.Join(directory, membershipSecretName))
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
// supervisor's enrollment entry on a bounded interval. It depends on the cluster
// so the update lands only while the owner's mesh is up. Start returns as soon as
// the first publish succeeds; the periodic refresh runs until Stop cancels it.
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
	secret, err := readMembershipSecret(directory)
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

// publishSupervisor records the live Hive supervisor address in the rendezvous
// descriptor. A raft-disabled owner never registers the cluster-wide name, so
// this direct address is how a local client reaches the supervisor. The
// supervisor registers its local name at boot; until then the descriptor carries
// no address and the client keeps waiting.
func (p *enrollmentPublisherComponent) publishSupervisor(ctx context.Context) {
	pidRegistry := topapi.GetRegistry(ctx)
	if pidRegistry == nil {
		return
	}
	supervisor, found := pidRegistry.Lookup("bee.hive.supervisor")
	if !found || supervisor.Node != p.node || supervisor.Host != "bee.hive:supervisor_host" || supervisor.UniqID == "" {
		return
	}
	store, err := rendezvous.New(filepath.Join(p.state, rendezvous.DirectoryName))
	if err != nil {
		return
	}
	descriptor, err := store.Read(ctx)
	if err != nil || descriptor.Supervisor == supervisor.String() {
		return
	}
	descriptor.Supervisor = supervisor.String()
	_ = store.Publish(ctx, descriptor)
}

type enrollmentPublisherComponent struct {
	state     string
	directory string
	trusted   string
	execution string
	node      string
	secret    []byte
	cancel    context.CancelFunc
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
		if err := errors.Join(removed, unlock(), os.Remove(filepath.Join(trusted, clientLockName(node)))); err != nil {
			return err
		}
	}
	return nil
}

// publish mirrors one snapshot of the trusted directory. A client waits on the
// local enrollment and then sends its first request, and the supervisor admits
// from the host entry, so the entry is written first and the local enrollment
// lists only the nodes that write named.
func (p *enrollmentPublisherComponent) publish(ctx context.Context, reg registry.Registry, enrollment *rendezvous.Enrollment) error {
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
	if _, err := reg.Apply(ctx, enrollmentChange(keys, peers)); err != nil {
		return err
	}
	if err := p.seedEnrollment(ctx, enrollment, keys); err != nil {
		return err
	}
	p.publishSupervisor(ctx)
	return nil
}

// Start arms the publisher and returns. It must not publish yet: the runtime
// starts boot components before it applies the deployment's registry entries,
// so the enrollment entry does not exist at this point. Each refresh publishes
// one snapshot; until the entry exists the write is refused and nothing is
// listed locally.
func (p *enrollmentPublisherComponent) Start(ctx context.Context) error {
	reg := registry.GetRegistry(ctx)
	if reg == nil {
		return errors.New("enrollment publisher requires the registry")
	}
	log := logs.GetLogger(ctx).Named("bee.launch.enrollment")
	enrollment, err := rendezvous.NewEnrollment(p.directory)
	if err != nil {
		return err
	}
	lifetime, cancel := context.WithCancel(context.WithoutCancel(ctx))
	p.cancel = cancel
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		published := false
		for {
			if err := p.publish(lifetime, reg, enrollment); err != nil {
				// Before the first publish the entry is still being applied.
				if published {
					log.Warn("enrollment publication failed", zap.Error(err))
				} else {
					log.Debug("enrollment entry not yet writable", zap.Error(err))
				}
			} else {
				published = true
			}
			select {
			case <-lifetime.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	return nil
}

func (p *enrollmentPublisherComponent) Stop(context.Context) error {
	if p.cancel != nil {
		p.cancel()
		p.cancel = nil
	}
	return nil
}
