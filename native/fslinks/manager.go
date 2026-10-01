// SPDX-License-Identifier: MIT

package fslinks

import (
	"context"
	"io/fs"
	"sync"

	"github.com/wippyai/runtime/api/event"
	fsapi "github.com/wippyai/runtime/api/fs"
	"github.com/wippyai/runtime/api/payload"
	"github.com/wippyai/runtime/api/registry"
	"github.com/wippyai/runtime/system/entry"
)

const Kind registry.Kind = "bee.fs.selected_links"

type Config struct {
	Root  string `json:"root" yaml:"root"`
	Links []Link `json:"links" yaml:"links"`
}

type Manager struct {
	bus        event.Bus
	transcoder payload.Transcoder
	mu         sync.Mutex
	volumes    map[registry.ID]*FS
}

func NewManager(bus event.Bus, transcoder payload.Transcoder) *Manager {
	return &Manager{bus: bus, transcoder: transcoder, volumes: make(map[registry.ID]*FS)}
}

func (manager *Manager) configure(ctx context.Context, resource registry.Entry, update bool) error {
	if resource.Kind != Kind {
		return fs.ErrInvalid
	}
	config, err := entry.DecodeEntryConfig[Config](ctx, manager.transcoder, resource)
	if err != nil {
		return err
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	previous, exists := manager.volumes[resource.ID]
	if exists != update {
		return fs.ErrInvalid
	}
	volume, err := New(config.Root, config.Links)
	if err != nil {
		return err
	}
	manager.volumes[resource.ID] = volume
	manager.bus.Send(ctx, event.Event{System: fsapi.System, Kind: fsapi.FsRegister, Path: resource.ID.String(), Data: volume})
	if previous != nil {
		return previous.Close()
	}
	return nil
}

func (manager *Manager) Add(ctx context.Context, resource registry.Entry) error {
	return manager.configure(ctx, resource, false)
}

func (manager *Manager) Update(ctx context.Context, resource registry.Entry) error {
	return manager.configure(ctx, resource, true)
}

func (manager *Manager) Delete(ctx context.Context, resource registry.Entry) error {
	if resource.Kind != Kind {
		return fs.ErrInvalid
	}
	manager.mu.Lock()
	defer manager.mu.Unlock()
	previous, exists := manager.volumes[resource.ID]
	if !exists {
		return fs.ErrNotExist
	}
	delete(manager.volumes, resource.ID)
	manager.bus.Send(ctx, event.Event{System: fsapi.System, Kind: fsapi.FsDelete, Path: resource.ID.String()})
	return previous.Close()
}
