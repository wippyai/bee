// SPDX-License-Identifier: MIT
package service

import (
	"strings"
	"testing"
	"time"

	"github.com/wippyai/runtime/api/registry"
)

func desktopConfig() Config {
	return Config{Enabled: true, Policies: []string{DesktopHostPolicy}, Desktop: &DesktopConfig{
		Execution: strings.Repeat("a", 32), ExpiresAt: time.Now().UTC().Add(time.Hour).Truncate(time.Millisecond), AllowedNodes: []string{"client"}, Application: "bee.console:app"}}
}
func TestDesktopConfigRejectsImplicitAdmission(t *testing.T) {
	if err := desktopConfig().Validate(); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(*Config){
		"disabled":        func(c *Config) { c.Enabled = false },
		"no policy":       func(c *Config) { c.Policies = []string{"bee:other"} },
		"no nodes":        func(c *Config) { c.Desktop.AllowedNodes = nil },
		"duplicate nodes": func(c *Config) { c.Desktop.AllowedNodes = []string{"client", "client"} },
		"bad node":        func(c *Config) { c.Desktop.AllowedNodes = []string{"client\n"} },
		"expired":         func(c *Config) { c.Desktop.ExpiresAt = time.Now().Add(-time.Second).Truncate(time.Millisecond) },
		"submillisecond":  func(c *Config) { c.Desktop.ExpiresAt = c.Desktop.ExpiresAt.Add(time.Nanosecond) },
		"execution":       func(c *Config) { c.Desktop.Execution = strings.Repeat("A", 32) },
		"application":     func(c *Config) { c.Desktop.Application = "unqualified" },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			c := desktopConfig()
			change(&c)
			if c.Validate() == nil {
				t.Fatal("invalid desktop grant accepted")
			}
		})
	}
}
func TestDesktopHostConfigAndPayloadHaveIndependentOwnership(t *testing.T) {
	original := desktopConfig()
	copied := original.clone()
	original.Desktop.AllowedNodes[0] = "untrusted"
	original.Desktop.Execution = strings.Repeat("b", 32)
	if copied.Desktop.AllowedNodes[0] != "client" || copied.Desktop.Execution == original.Desktop.Execution {
		t.Fatal("host configuration aliases caller storage")
	}
	input := copied.Desktop.input()
	nodes, ok := input["allowed_nodes"].([]string)
	if !ok {
		t.Fatal("node list type lost")
	}
	nodes[0] = "mutated"
	if copied.Desktop.AllowedNodes[0] != "client" {
		t.Fatal("service payload aliases configuration")
	}
	if input["expires_at"] != copied.Desktop.ExpiresAt.UTC().Format(desktopTimeFormat) || input["application"] != "bee.console:app" {
		t.Fatal("desktop payload differs from trusted host configuration")
	}
	l := activationListener{cfg: copied}
	_, lifecycle := l.createSupervisedService(registry.ParseID(ActivationID))
	if len(lifecycle.Requires) != 2 || lifecycle.Requires[0] != HostID || lifecycle.Requires[1] != "bee:workers" {
		t.Fatalf("desktop dependency ordering: %v", lifecycle.Requires)
	}
}
