// SPDX-License-Identifier: MIT

// Package host gives Bee's components a read-only view of nonsecret host
// facts: the running Bee executable, the home and working folders, the names
// (never the values) of the environment variables, and the absolute path of
// an installed executable by its bare name. Drivers locate the harnesses
// installed on the machine through it, and generated hooks call back into the
// same Bee instead of finding another one on PATH.
package host

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strings"

	"github.com/wippyai/runtime/api/boot"
	envapi "github.com/wippyai/runtime/api/env"
	"github.com/wippyai/runtime/api/registry"
)

// StorageID is the environment storage the host facts are read through.
const StorageID = "bee.harness.host:environment"

type hostResolver struct {
	lookPath         func(string) (string, error)
	homeDir          func() (string, error)
	getwd            func() (string, error)
	executable       func() (string, error)
	environmentNames func() []string
	buildInfo        func() (*debug.BuildInfo, bool)
}

func systemHostResolver() hostResolver {
	return hostResolver{
		lookPath:         exec.LookPath,
		homeDir:          os.UserHomeDir,
		getwd:            os.Getwd,
		executable:       os.Executable,
		environmentNames: systemEnvironmentNames,
		buildInfo:        debug.ReadBuildInfo,
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

type hostEnvironment struct {
	resolver hostResolver
	facts    map[string]string
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
	facts := map[string]string{"home": home, "cwd": cwd, "self": self, "environment_names": string(encodedNames)}
	if identity := resolvedBinaryIdentity(resolver.buildInfo); identity != "" {
		facts["binary_identity"] = identity
	}
	return &hostEnvironment{resolver: resolver, facts: facts}, nil
}

func resolvedBinaryIdentity(read func() (*debug.BuildInfo, bool)) string {
	if read == nil {
		return ""
	}
	info, ok := read()
	if !ok || info == nil {
		return ""
	}
	modules := make(map[string]string)
	for _, module := range append([]*debug.Module{&info.Main}, info.Deps...) {
		selected := module
		if module.Replace != nil {
			if module.Replace.Path != module.Path {
				continue
			}
			selected = module.Replace
		}
		if strings.HasPrefix(selected.Version, "v") {
			modules[module.Path] = selected.Version
		}
	}
	const nativeModule = "github.com/wippyai/bee/native"
	runtimeVersion := modules["github.com/wippyai/runtime"]
	nativeVersion := modules[nativeModule]
	if runtimeVersion == "" || nativeVersion == "" {
		return ""
	}
	encoded, err := json.Marshal(struct {
		NativeModule  string            `json:"native_module"`
		NativeVersion string            `json:"native_version"`
		NativeModules map[string]string `json:"native_modules"`
		RuntimeCommit string            `json:"runtime_commit"`
	}{nativeModule, nativeVersion, modules, runtimeVersion})
	if err != nil {
		return ""
	}
	return string(encoded)
}

func safeExecutableName(name string) bool {
	return name != "" && name != "." && name != ".." && !filepath.IsAbs(name) &&
		!strings.ContainsAny(name, `/\`) && !strings.Contains(name, "..")
}

func (storage *hostEnvironment) Get(_ context.Context, name string) (string, error) {
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

func (*hostEnvironment) Set(context.Context, string, string) error {
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

// Component registers the host environment storage at boot.
type Component struct{}

// New returns the host environment component.
func New() *Component { return &Component{} }

// Name implements boot.Component.
func (*Component) Name() string { return "bee.host" }

// DependsOn implements boot.Component: the storage registers into the
// environment registry the env component creates.
func (*Component) DependsOn() []string { return []string{"env"} }

// Load implements boot.Component: it registers the storage before the
// registry's environment variables are read.
func (*Component) Load(ctx context.Context) (context.Context, error) {
	environment := envapi.GetRegistry(ctx)
	if environment == nil {
		return ctx, errors.New("bee host: environment registry is unavailable")
	}
	storage, err := newHostEnvironment(systemHostResolver())
	if err != nil {
		return ctx, err
	}
	environment.RegisterStorage(registry.ParseID(StorageID), storage)
	return ctx, nil
}

// Start implements boot.Component.
func (*Component) Start(context.Context) error { return nil }

// Stop implements boot.Component.
func (*Component) Stop(context.Context) error { return nil }

var _ boot.Component = (*Component)(nil)
