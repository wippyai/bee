// SPDX-License-Identifier: MIT
package harnesshost

import (
	"context"
	"errors"
	"testing"

	envapi "github.com/wippyai/runtime/api/env"
)

func resolver(paths map[string]string) Resolver {
	return Resolver{
		LookPath: func(name string) (string, error) {
			if p, ok := paths[name]; ok {
				return p, nil
			}
			return "", errors.New("not found")
		},
		HomeDir: func() (string, error) { return "/home/test", nil }, Getwd: func() (string, error) { return "/work/test", nil },
	}
}
func TestStorageExposesOnlyNonsecretHostPaths(t *testing.T) {
	s, err := NewStorage(resolver(map[string]string{"claude": "/opt/bin/claude", "relative": "bin/tool"}))
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"home": "/home/test", "cwd": "/work/test", "claude": "/opt/bin/claude"} {
		got, err := s.Get(context.Background(), name)
		if err != nil || got != want {
			t.Fatalf("Get(%q) = %q, %v", name, got, err)
		}
	}
	for _, name := range []string{"missing", "../claude", "/usr/bin/claude", ".", "relative"} {
		if _, err := s.Get(context.Background(), name); !errors.Is(err, envapi.ErrVariableNotFound) {
			t.Fatalf("Get(%q) error = %v", name, err)
		}
	}
	if err := s.Set(context.Background(), "claude", "/other"); err == nil {
		t.Fatal("Set succeeded")
	}
	if err := s.Delete(context.Background(), "claude"); err == nil {
		t.Fatal("Delete succeeded")
	}
	all, err := s.List(context.Background())
	if err != nil || len(all) != 2 || all["home"] != "/home/test" || all["cwd"] != "/work/test" {
		t.Fatalf("List() = %#v, %v", all, err)
	}
}
func TestStorageRefusesIncompleteOrRelativeHostFacts(t *testing.T) {
	_, err := NewStorage(Resolver{})
	if err == nil {
		t.Fatal("incomplete resolver succeeded")
	}
	r := resolver(nil)
	r.HomeDir = func() (string, error) { return "relative", nil }
	if _, err := NewStorage(r); err == nil {
		t.Fatal("relative home succeeded")
	}
}
