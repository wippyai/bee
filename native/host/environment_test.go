// SPDX-License-Identifier: MIT

package host

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
	envapi "github.com/wippyai/runtime/api/env"
)

func resolver() hostResolver {
	return hostResolver{
		lookPath: func(name string) (string, error) {
			if name == "claude" {
				return "/usr/local/bin/claude", nil
			}
			return "", errors.New("not found")
		},
		homeDir:          func() (string, error) { return "/home/person", nil },
		getwd:            func() (string, error) { return "/home/person/project", nil },
		executable:       func() (string, error) { return "/home/person/.local/bin/bee", nil },
		environmentNames: func() []string { return []string{"HOME", "PATH"} },
	}
}

func TestHostEnvironmentNamesTheRunningBeeAndItsFolders(t *testing.T) {
	storage, err := newHostEnvironment(resolver())
	require.NoError(t, err)
	ctx := context.Background()
	for name, want := range map[string]string{"self": "/home/person/.local/bin/bee", "home": "/home/person", "cwd": "/home/person/project"} {
		got, err := storage.Get(ctx, name)
		require.NoError(t, err)
		require.Equal(t, want, got, name)
	}
}

func TestHostEnvironmentListsVariableNamesWithoutValues(t *testing.T) {
	storage, err := newHostEnvironment(resolver())
	require.NoError(t, err)
	raw, err := storage.Get(context.Background(), "environment_names")
	require.NoError(t, err)
	var names []string
	require.NoError(t, json.Unmarshal([]byte(raw), &names))
	require.Equal(t, []string{"HOME", "PATH"}, names)
}

func TestHostEnvironmentResolvesInstalledExecutablesOnly(t *testing.T) {
	storage, err := newHostEnvironment(resolver())
	require.NoError(t, err)
	ctx := context.Background()
	path, err := storage.Get(ctx, "claude")
	require.NoError(t, err)
	require.Equal(t, "/usr/local/bin/claude", path)
	_, err = storage.Get(ctx, "codex")
	require.ErrorIs(t, err, envapi.ErrVariableNotFound)
	for _, unsafe := range []string{"", ".", "..", "/bin/sh", "a/b", "..sh"} {
		_, err = storage.Get(ctx, unsafe)
		require.ErrorIs(t, err, envapi.ErrVariableNotFound, unsafe)
	}
}

func TestHostEnvironmentIsReadOnly(t *testing.T) {
	storage, err := newHostEnvironment(resolver())
	require.NoError(t, err)
	require.Error(t, storage.Set(context.Background(), "self", "/tmp/other"))
	require.Error(t, storage.Delete(context.Background(), "self"))
}

func TestHostEnvironmentRefusesRelativeFacts(t *testing.T) {
	broken := resolver()
	broken.executable = func() (string, error) { return "bee", nil }
	_, err := newHostEnvironment(broken)
	require.Error(t, err)
}

func TestComponentLoadsAfterTheEnvironmentRegistry(t *testing.T) {
	deps := New().DependsOn()
	for _, name := range deps {
		if name == "env" {
			return
		}
	}
	t.Fatalf("bee.host depends on %v, want the env component that creates the environment registry", deps)
}
