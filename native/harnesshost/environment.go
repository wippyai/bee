// SPDX-License-Identifier: MIT

// Package harnesshost exposes nonsecret host facts to declared driver variables.
package harnesshost

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/wippyai/runtime/api/boot"
	envapi "github.com/wippyai/runtime/api/env"
	"github.com/wippyai/runtime/api/registry"
	bootsystem "github.com/wippyai/runtime/boot/components/system"
)

const (
	ComponentName boot.Name = "bee.harness.host.environment"
	StorageID               = "bee.harness.host:environment"
)

type Resolver struct {
	LookPath func(string) (string, error)
	HomeDir  func() (string, error)
	Getwd    func() (string, error)
}

func systemResolver() Resolver {
	return Resolver{LookPath: exec.LookPath, HomeDir: os.UserHomeDir, Getwd: os.Getwd}
}

// Storage is a fixed snapshot of nonsecret host paths. It never reads files or
// changes the process environment.
type Storage struct {
	resolver Resolver
	facts    map[string]string
}

func NewStorage(resolver Resolver) (*Storage, error) {
	if resolver.LookPath == nil || resolver.HomeDir == nil || resolver.Getwd == nil {
		return nil, errors.New("host path resolver is incomplete")
	}
	home, err := resolver.HomeDir()
	if err != nil {
		return nil, err
	}
	cwd, err := resolver.Getwd()
	if err != nil {
		return nil, err
	}
	if !filepath.IsAbs(home) || !filepath.IsAbs(cwd) {
		return nil, errors.New("host facts must be absolute paths")
	}
	return &Storage{resolver: resolver, facts: map[string]string{"home": home, "cwd": cwd}}, nil
}

func bare(name string) bool {
	return name != "" && name != "." && !strings.ContainsAny(name, `/\\`) && !strings.Contains(name, "..")
}
func (s *Storage) Get(_ context.Context, name string) (string, error) {
	if value, ok := s.facts[name]; ok {
		return value, nil
	}
	if !bare(name) {
		return "", envapi.ErrVariableNotFound
	}
	path, err := s.resolver.LookPath(name)
	if err != nil || !filepath.IsAbs(path) {
		return "", envapi.ErrVariableNotFound
	}
	return path, nil
}
func (s *Storage) Set(context.Context, string, string) error {
	return errors.New("host environment is read-only")
}
func (s *Storage) Delete(context.Context, string) error {
	return errors.New("host environment is read-only")
}
func (s *Storage) List(context.Context) (map[string]string, error) {
	out := make(map[string]string, len(s.facts))
	for k, v := range s.facts {
		out[k] = v
	}
	return out, nil
}

func Component() boot.Component {
	return boot.New(boot.P{Name: ComponentName, DependsOn: []boot.Name{bootsystem.EnvironmentName}, Load: func(ctx context.Context) (context.Context, error) {
		reg := envapi.GetRegistry(ctx)
		if reg == nil {
			return ctx, errors.New("environment registry is unavailable")
		}
		storage, err := NewStorage(systemResolver())
		if err != nil {
			return ctx, err
		}
		reg.RegisterStorage(registry.NewID("bee.harness.host", "environment"), storage)
		return ctx, nil
	}})
}
