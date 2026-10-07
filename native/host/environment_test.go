// SPDX-License-Identifier: MIT

package host

import (
	"context"
	"encoding/json"
	"errors"
	"runtime/debug"
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

func TestHostEnvironmentExposesResolvedBinaryIdentity(t *testing.T) {
	r := resolver()
	r.buildInfo = func() (*debug.BuildInfo, bool) {
		return &debug.BuildInfo{Deps: []*debug.Module{
			{Path: "github.com/wippyai/runtime", Version: "v0.1.14-0.20261007011850-2bb9e144ab06"},
			{Path: "github.com/wippyai/bee/native", Version: "v0.0.0-20261007013720-bdd1c66d0ea1"},
			{Path: "example.test/native", Version: "v1.2.3"},
		}}, true
	}
	storage, err := newHostEnvironment(r)
	require.NoError(t, err)
	raw, err := storage.Get(context.Background(), "binary_identity")
	require.NoError(t, err)
	var got map[string]any
	require.NoError(t, json.Unmarshal([]byte(raw), &got))
	require.Equal(t, "v0.1.14-0.20261007011850-2bb9e144ab06", got["runtime_commit"])
	require.Equal(t, "github.com/wippyai/bee/native", got["native_module"])
	require.Equal(t, "v0.0.0-20261007013720-bdd1c66d0ea1", got["native_version"])
	require.Equal(t, map[string]any{
		"github.com/wippyai/runtime":    "v0.1.14-0.20261007011850-2bb9e144ab06",
		"github.com/wippyai/bee/native": "v0.0.0-20261007013720-bdd1c66d0ea1",
		"example.test/native":           "v1.2.3",
	}, got["native_modules"])
}

func TestHostEnvironmentOmitsUnverifiableBinaryIdentity(t *testing.T) {
	for _, info := range []*debug.BuildInfo{nil, {Deps: []*debug.Module{
		{Path: "github.com/wippyai/runtime", Version: "v1.2.3", Replace: &debug.Module{Path: "../runtime"}},
		{Path: "github.com/wippyai/bee/native", Version: "v1.0.0"},
	}}} {
		r := resolver()
		r.buildInfo = func() (*debug.BuildInfo, bool) { return info, info != nil }
		storage, err := newHostEnvironment(r)
		require.NoError(t, err)
		facts, err := storage.List(context.Background())
		require.NoError(t, err)
		require.NotContains(t, facts, "binary_identity")
	}
}
