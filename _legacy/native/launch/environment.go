// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	envapi "github.com/wippyai/runtime/api/env"
)

type hostResolver struct {
	lookPath         func(string) (string, error)
	homeDir          func() (string, error)
	getwd            func() (string, error)
	executable       func() (string, error)
	environmentNames func() []string
	binary           func() binaryIdentityFacts
}

func systemHostResolver() hostResolver {
	return hostResolver{
		lookPath:         exec.LookPath,
		homeDir:          os.UserHomeDir,
		getwd:            os.Getwd,
		executable:       os.Executable,
		environmentNames: systemEnvironmentNames,
		binary:           readBinaryIdentityFacts,
	}
}

// systemEnvironmentNames exposes only presence metadata, never values.
func systemEnvironmentNames() []string {
	names := make([]string, 0)
	for _, entry := range os.Environ() {
		if name, _, found := strings.Cut(entry, "="); found {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

// hostEnvironment is a read-only view of nonsecret host facts. The runtime's
// normal environment providers remain responsible for user variables and
// writes; this storage only gives declared native integrations a few facts and
// safe PATH lookups.
type hostEnvironment struct {
	resolver hostResolver
	facts    map[string]string
	startup  *startupMonitor
}

func newHostEnvironment(resolver hostResolver) (*hostEnvironment, error) {
	if resolver.lookPath == nil || resolver.homeDir == nil || resolver.getwd == nil || resolver.executable == nil {
		return nil, errors.New("host path resolver is incomplete")
	}
	home, err := resolver.homeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve host home: %w", err)
	}
	cwd, err := resolver.getwd()
	if err != nil {
		return nil, fmt.Errorf("resolve host working directory: %w", err)
	}
	self, err := resolver.executable()
	if err != nil {
		return nil, fmt.Errorf("resolve Bee executable: %w", err)
	}
	for name, value := range map[string]string{"home": home, "cwd": cwd, "self": self} {
		if !filepath.IsAbs(value) {
			return nil, errors.New("host " + name + " must be an absolute path")
		}
	}
	names := []string{}
	if resolver.environmentNames != nil {
		names = resolver.environmentNames()
	}
	encodedNames, err := json.Marshal(names)
	if err != nil {
		return nil, fmt.Errorf("encode host environment names: %w", err)
	}
	facts := map[string]string{
		"home":              home,
		"cwd":               cwd,
		"self":              self,
		"environment_names": string(encodedNames),
	}
	binary := resolver.binary
	if binary == nil {
		binary = readBinaryIdentityFacts
	}
	identity := binary()
	for name, value := range map[string]string{
		"binary_native_module":  identity.NativeModule,
		"binary_native_version": identity.NativeVersion,
		"binary_native_modules": identity.NativeModules,
		"binary_runtime_commit": identity.RuntimeCommit,
	} {
		if value != "" {
			facts[name] = value
		}
	}
	return &hostEnvironment{resolver: resolver, facts: facts}, nil
}

func safeExecutableName(name string) bool {
	return name != "" && name != "." && name != ".." && !filepath.IsAbs(name) &&
		!strings.ContainsAny(name, `/\\`) && !strings.Contains(name, "..")
}

func (storage *hostEnvironment) Get(ctx context.Context, name string) (string, error) {
	if name == "startup_progress" {
		if storage.startup == nil {
			return "", nil
		}
		return storage.startup.Get(ctx, "progress")
	}
	if name == "startup_sequence" || name == "startup_phase" {
		if storage.startup != nil {
			return storage.startup.Get(ctx, strings.TrimPrefix(name, "startup_"))
		}
		if name == "startup_sequence" {
			return "0", nil
		}
		return "starting", nil
	}
	if value, ok := storage.facts[name]; ok {
		return value, nil
	}
	if !safeExecutableName(name) {
		return "", envapi.ErrVariableNotFound
	}
	path, err := storage.resolver.lookPath(name)
	if err != nil || !filepath.IsAbs(path) {
		return "", envapi.ErrVariableNotFound
	}
	return path, nil
}

func (storage *hostEnvironment) Set(ctx context.Context, name, value string) error {
	if storage.startup != nil {
		if name == "startup_phase" {
			return storage.startup.Set(ctx, "phase", value)
		}
		if name == "startup_progress" {
			return storage.startup.Set(ctx, "progress", value)
		}
	}
	return errors.New("host environment is read-only")
}

func (*hostEnvironment) Delete(context.Context, string) error {
	return errors.New("host environment is read-only")
}

func (storage *hostEnvironment) List(context.Context) (map[string]string, error) {
	values := make(map[string]string, len(storage.facts))
	for name, value := range storage.facts {
		values[name] = value
	}
	return values, nil
}
