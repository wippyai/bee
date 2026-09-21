// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	envapi "github.com/wippyai/runtime/api/env"
)

type hostResolver struct {
	lookPath   func(string) (string, error)
	homeDir    func() (string, error)
	getwd      func() (string, error)
	executable func() (string, error)
}

func systemHostResolver() hostResolver {
	return hostResolver{
		lookPath:   exec.LookPath,
		homeDir:    os.UserHomeDir,
		getwd:      os.Getwd,
		executable: os.Executable,
	}
}

// hostEnvironment is a read-only view of nonsecret host facts. The runtime's
// normal environment providers remain responsible for user variables and
// writes; this storage only gives declared native integrations a few facts and
// safe PATH lookups.
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
	return &hostEnvironment{resolver: resolver, facts: map[string]string{
		"home": home,
		"cwd":  cwd,
		"self": self,
	}}, nil
}

func safeExecutableName(name string) bool {
	return name != "" && name != "." && name != ".." && !filepath.IsAbs(name) &&
		!strings.ContainsAny(name, `/\\`) && !strings.Contains(name, "..")
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
