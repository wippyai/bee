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

	"github.com/wippyai/bee/native/hive/rendezvous"

	"github.com/wippyai/runtime/api/attrs"
	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/registry"
)

const (
	// enrollmentEntry is the host-owned registry entry the Hive supervisor
	// reconciles (src/hive/supervisor/enrollment.lua). The owner rewrites it
	// from its trusted directory, so a local client node is admitted exactly
	// while its public key file exists.
	enrollmentEntry = "bee.hive.supervisor:enrollment_nodes"
	// enrollmentEntryKind must match the entry's declared kind, so the update is
	// a same-kind replacement the registry accepts.
	enrollmentEntryKind = "registry.entry"
)

// enrollmentChangeSet builds the one-entry update that publishes the enrolled
// local client nodes. It follows the runtime's own host-entry write path
// (cmd/internal/entries/loader.go ApplyToRegistry -> Registry.Apply with an
// EntryUpdate operation); a malformed or non-key file is never admitted.
func enrollmentChangeSet(trusted string) (registry.ChangeSet, error) {
	nodes, err := trustedNodes(trusted)
	if err != nil {
		return nil, err
	}
	entry := registry.Entry{
		ID:   registry.ParseID(enrollmentEntry),
		Kind: enrollmentEntryKind,
		Data: payload.New(map[string]any{"nodes": nodes}),
		Meta: attrs.NewBagFrom(map[string]any{"type": "bee.hive.supervisor_enrollment"}),
	}
	return registry.ChangeSet{{Kind: registry.EntryUpdate, Entry: entry}}, nil
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

// trustedNodes lists the enrolled client nodes from the trusted directory,
// validating each key before it is admitted.
func trustedNodes(trusted string) ([]any, error) {
	entries, err := os.ReadDir(trusted)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return []any{}, nil
		}
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".pub") {
			continue
		}
		node := strings.TrimSuffix(entry.Name(), ".pub")
		if !validTrustedName(node) {
			continue
		}
		if _, ok := resolveTrustedKey(trusted, node); !ok {
			continue
		}
		names = append(names, node)
	}
	sort.Strings(names)
	out := make([]any, 0, len(names))
	for _, name := range names {
		out = append(out, name)
	}
	return out, nil
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
	p := &enrollmentPublisherComponent{directory: directory, trusted: trusted, execution: execution, secret: secret}
	return boot.New(boot.P{
		Name:      "bee.launch.enrollment",
		DependsOn: []string{"cluster"},
		Start:     p.Start,
		Stop:      p.Stop,
	}), nil
}

type enrollmentPublisherComponent struct {
	directory string
	trusted   string
	execution string
	secret    []byte
	cancel    context.CancelFunc
}

// seedEnrollment initializes the owner's local enrollment from its membership
// secret and registers every trusted client key under its node name, so the
// joining client's mesh handshake resolves.
func (p *enrollmentPublisherComponent) seedEnrollment(ctx context.Context, enrollment *rendezvous.Enrollment) error {
	if err := enrollment.Initialize(ctx, p.execution, p.secret); err != nil {
		return err
	}
	entries, err := os.ReadDir(p.trusted)
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
		public, ok := resolveTrustedKey(p.trusted, node)
		if !ok {
			continue
		}
		if _, err := enrollment.Register(ctx, p.execution, node, public); err != nil {
			return err
		}
	}
	return nil
}

// Start arms the publisher and returns. It must not publish yet: the runtime
// starts boot components before it applies the deployment's registry entries, so
// the enrollment entry does not exist at this point. The first refresh retries
// until the entry appears, then mirrors the trusted directory for the owner's
// lifetime.
func (p *enrollmentPublisherComponent) Start(ctx context.Context) error {
	reg := registry.GetRegistry(ctx)
	if reg == nil {
		return errors.New("enrollment publisher requires the registry")
	}
	lifetime, cancel := context.WithCancel(context.WithoutCancel(ctx))
	p.cancel = cancel
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		// Seed the local enrollment the joining client reads: the owner's gossip
		// secret plus this node's mesh identity, and one entry per trusted client
		// key. The client registers itself under the node it announces.
		enrollment, err := rendezvous.NewEnrollment(p.directory)
		if err != nil {
			return
		}
		for {
			if err := p.seedEnrollment(lifetime, enrollment); err == nil {
				break
			}
			select {
			case <-lifetime.Done():
				return
			case <-ticker.C:
			}
		}
		publish := func() {
			changes, err := enrollmentChangeSet(p.trusted)
			if err == nil {
				_, _ = reg.Apply(lifetime, changes)
			}
			_ = p.seedEnrollment(lifetime, enrollment)
		}
		publish()
		for {
			select {
			case <-lifetime.Done():
				return
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
		p.cancel = nil
	}
	return nil
}

var _ = ed25519.PublicKeySize
var _ = base64.StdEncoding
