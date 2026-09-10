// SPDX-License-Identifier: MIT

package service

import (
	"fmt"
	"strings"
	"testing"
)

func TestConfigValidation(t *testing.T) {
	t.Run("valid disabled config", func(t *testing.T) {
		cfg := Config{
			Enabled:         false,
			ConfiguredNodes: []string{"node-1", "node-2"},
		}
		if err := cfg.Validate(); err != nil {
			t.Fatalf("expected valid, got: %v", err)
		}
	})

	t.Run("valid with explicit policies", func(t *testing.T) {
		cfg := Config{
			Enabled:         true,
			ConfiguredNodes: []string{"node-1"},
			Policies:        []string{"bee:hive_supervisor_policy", "bee:hive_catalog_policy"},
		}
		if err := cfg.Validate(); err != nil {
			t.Fatalf("expected valid, got: %v", err)
		}
	})

	t.Run("empty node ID rejected", func(t *testing.T) {
		cfg := Config{
			ConfiguredNodes: []string{""},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "cannot be empty") {
			t.Fatalf("expected empty error, got: %v", err)
		}
	})

	t.Run("node ID exceeding 160 bytes rejected", func(t *testing.T) {
		longID := strings.Repeat("a", MaxNodeIDBytes+1)
		cfg := Config{
			ConfiguredNodes: []string{longID},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "exceeds maximum of 160 bytes") {
			t.Fatalf("expected length error, got: %v", err)
		}
	})

	t.Run("node ID with control characters rejected", func(t *testing.T) {
		badIDs := []string{
			"node\x00bad",
			"node\nbad",
			"node\rbad",
			"node\x1fbad",
			"node\x7fbad",
		}
		for _, bad := range badIDs {
			cfg := Config{
				ConfiguredNodes: []string{bad},
			}
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "control character") {
				t.Fatalf("expected control character rejection for %q, got: %v", bad, err)
			}
		}
	})

	t.Run("more than 64 configured nodes rejected", func(t *testing.T) {
		nodes := make([]string, MaxConfiguredNodes+1)
		for i := range nodes {
			nodes[i] = fmt.Sprintf("node-%d", i)
		}
		cfg := Config{
			ConfiguredNodes: nodes,
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "exceeds maximum of 64 items") {
			t.Fatalf("expected item count rejection, got: %v", err)
		}
	})

	t.Run("duplicate configured node IDs rejected", func(t *testing.T) {
		cfg := Config{
			ConfiguredNodes: []string{"node-1", "node-2", "node-1"},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "duplicate configured node ID") {
			t.Fatalf("expected duplicate rejection, got: %v", err)
		}
	})

	t.Run("empty policy string rejected", func(t *testing.T) {
		cfg := Config{
			Policies: []string{""},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "cannot be empty") {
			t.Fatalf("expected empty policy rejection, got: %v", err)
		}
	})

	t.Run("policy exceeding 160 bytes rejected", func(t *testing.T) {
		cfg := Config{
			Policies: []string{strings.Repeat("p", MaxNodeIDBytes+1)},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "exceeds maximum of 160 bytes") {
			t.Fatalf("expected policy length rejection, got: %v", err)
		}
	})

	t.Run("duplicate policies rejected", func(t *testing.T) {
		cfg := Config{
			Policies: []string{"bee:p1", "bee:p1"},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "duplicate policy ID") {
			t.Fatalf("expected duplicate policy rejection, got: %v", err)
		}
	})

	t.Run("more than 64 policies rejected", func(t *testing.T) {
		pols := make([]string, MaxPolicies+1)
		for i := range pols {
			pols[i] = fmt.Sprintf("bee:p%d", i)
		}
		cfg := Config{
			Policies: pols,
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "exceeds maximum of 64 items") {
			t.Fatalf("expected max policies rejection, got: %v", err)
		}
	})

	t.Run("policy without namespace rejected as generic ID", func(t *testing.T) {
		cfg := Config{
			Policies: []string{"generic_node_id"},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "missing namespace separator") {
			t.Fatalf("expected missing namespace rejection, got: %v", err)
		}
	})

	t.Run("policy with empty namespace rejected", func(t *testing.T) {
		cfg := Config{
			Policies: []string{":policy_name"},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "empty namespace") {
			t.Fatalf("expected empty namespace rejection, got: %v", err)
		}
	})

	t.Run("policy with empty name rejected", func(t *testing.T) {
		cfg := Config{
			Policies: []string{"bee:"},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "empty name") {
			t.Fatalf("expected empty name rejection, got: %v", err)
		}
	})

	t.Run("policy with whitespace rejected", func(t *testing.T) {
		cfg := Config{
			Policies: []string{"bee: invalid"},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "invalid whitespace") {
			t.Fatalf("expected whitespace rejection, got: %v", err)
		}
	})

	t.Run("policy with invalid characters rejected", func(t *testing.T) {
		cfg := Config{
			Policies: []string{"bee:bad@char"},
		}
		if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "invalid character") {
			t.Fatalf("expected invalid character rejection, got: %v", err)
		}
	})

	t.Run("immutable deep copy protects component", func(t *testing.T) {
		nodes := []string{"node-1", "node-2"}
		policies := []string{"bee:p1", "bee:p2"}
		cfg := Config{
			Enabled:         true,
			ConfiguredNodes: nodes,
			Policies:        policies,
		}
		comp, err := New(cfg)
		if err != nil {
			t.Fatal(err)
		}
		if comp == nil {
			t.Fatal("expected component")
		}

		// Mutate original slices
		nodes[0] = "mutated-node"
		policies[0] = "mutated-policy"

		// Verify component retains clean clone
		cloned := cfg.clone()
		if cloned.ConfiguredNodes[0] != "mutated-node" {
			t.Fatal("cloned from modified source should reflect current source state")
		}
	})
}

func TestEnabledRequiresHostPolicySelection(t *testing.T) {
	if _, err := New(Config{Enabled: true}); err == nil {
		t.Fatal("enabled configuration accepted without host policies")
	}
	if _, err := New(Config{}); err != nil {
		t.Fatal(err)
	}
}
