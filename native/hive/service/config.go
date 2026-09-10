// SPDX-License-Identifier: MIT

package service

import (
	"errors"
	"fmt"
	"slices"
	"strings"
)

const (
	// ActivationID is the exact registry identifier required to activate the service.
	ActivationID = "bee.hive:activation"

	// ActivationKind is the required registry entry kind.
	ActivationKind = "bee.hive.activation"

	// ProcessID is the target Lua supervisor process entry ID.
	ProcessID = "bee.hive.supervisor:main"

	// HostID is the dedicated protected process host for the Hive supervisor.
	HostID = "bee.hive:supervisor_host"

	// ActorID is the security actor ID under which the supervisor runs.
	ActorID = "bee.hive.supervisor"

	// ComponentName is the boot component name.
	ComponentName = "bee.hive.service"

	// MaxNodeIDBytes matches src/hive/bounds.MAX_ID_BYTES (160 bytes).
	MaxNodeIDBytes = 160

	// MaxConfiguredNodes matches src/hive/bounds.MAX_LIST_ITEMS (64 items).
	MaxConfiguredNodes = 64

	// MaxPolicies matches src/hive/bounds.MAX_LIST_ITEMS (64 items).
	MaxPolicies = 64
)

// Config provides immutable host-selected configuration for the native Hive service component.
// It contains no secrets and no Lua trust handles.
type Config struct {
	// Desktop is optional host-owned admission. Nil leaves the desktop bridge disabled.
	Desktop *DesktopConfig

	// Enabled determines whether the supervisor service is activated upon registry notification.
	// When false, activation entries are accepted as inert without registering a service.
	Enabled bool

	// ConfiguredNodes holds the bounded, unique native node IDs injected as supervisor host input.
	// Matches src/hive/bounds limits: length <= 64, each node ID non-empty, <= 160 bytes, no control chars.
	ConfiguredNodes []string

	// Policies lists the host-owned contract policies authorizing supervisor operations.
	// Required when enabled; registry activation data cannot supply this list.
	Policies []string
}

// Validate verifies that the configuration bounds and types comply with Bee Hive specifications.
func (c Config) Validate() error {
	if c.Desktop != nil {
		if !c.Enabled {
			return errors.New("desktop admission requires an enabled Hive service")
		}
		if !slices.Contains(c.Policies, DesktopHostPolicy) {
			return errors.New("desktop admission requires its explicit host policy")
		}
		if err := c.Desktop.validate(); err != nil {
			return err
		}
	}
	if c.Enabled && len(c.Policies) == 0 {
		return errors.New("enabled Hive service requires explicit host-selected policies")
	}
	if err := validateConfiguredNodes(c.ConfiguredNodes); err != nil {
		return err
	}
	if len(c.Policies) > 0 {
		if err := validatePolicies(c.Policies); err != nil {
			return err
		}
	}
	return nil
}

func (c Config) clone() Config {
	var nodes []string
	if c.ConfiguredNodes != nil {
		nodes = make([]string, len(c.ConfiguredNodes))
		copy(nodes, c.ConfiguredNodes)
	}
	var policies []string
	if c.Policies != nil {
		policies = make([]string, len(c.Policies))
		copy(policies, c.Policies)
	}
	return Config{
		Desktop:         c.Desktop.clone(),
		Enabled:         c.Enabled,
		ConfiguredNodes: nodes,
		Policies:        policies,
	}
}

func validateID(id string, fieldName string) error {
	if len(id) == 0 {
		return fmt.Errorf("%s cannot be empty", fieldName)
	}
	if len(id) > MaxNodeIDBytes {
		return fmt.Errorf("%s exceeds maximum of %d bytes (got %d)", fieldName, MaxNodeIDBytes, len(id))
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if c < 32 || c == 127 {
			return fmt.Errorf("%s contains invalid control character 0x%02x at byte %d", fieldName, c, i)
		}
	}
	return nil
}

func validateConfiguredNodes(nodes []string) error {
	if len(nodes) > MaxConfiguredNodes {
		return fmt.Errorf("configured_nodes exceeds maximum of %d items (got %d)", MaxConfiguredNodes, len(nodes))
	}
	seen := make(map[string]struct{}, len(nodes))
	for i, node := range nodes {
		if err := validateID(node, fmt.Sprintf("configured_nodes[%d]", i)); err != nil {
			return err
		}
		if _, exists := seen[node]; exists {
			return fmt.Errorf("duplicate configured node ID: %q", node)
		}
		seen[node] = struct{}{}
	}
	return nil
}

func validatePolicies(policies []string) error {
	if len(policies) == 0 {
		return errors.New("policies list cannot be empty when explicitly specified")
	}
	if len(policies) > MaxPolicies {
		return fmt.Errorf("policies exceeds maximum of %d items (got %d)", MaxPolicies, len(policies))
	}
	seen := make(map[string]struct{}, len(policies))
	for i, pol := range policies {
		if err := validateRegistryID(pol, fmt.Sprintf("policies[%d]", i)); err != nil {
			return err
		}
		if _, exists := seen[pol]; exists {
			return fmt.Errorf("duplicate policy ID: %q", pol)
		}
		seen[pol] = struct{}{}
	}
	return nil
}

func validateRegistryID(id string, fieldName string) error {
	if len(id) == 0 {
		return fmt.Errorf("%s cannot be empty", fieldName)
	}
	if len(id) > MaxNodeIDBytes {
		return fmt.Errorf("%s exceeds maximum of %d bytes (got %d)", fieldName, MaxNodeIDBytes, len(id))
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if c < 32 || c == 127 {
			return fmt.Errorf("%s contains invalid control character 0x%02x at byte %d", fieldName, c, i)
		}
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			return fmt.Errorf("%s contains invalid whitespace character at byte %d", fieldName, i)
		}
	}
	idx := strings.IndexByte(id, ':')
	if idx == -1 {
		return fmt.Errorf("%s is not a valid registry identifier: missing namespace separator ':' in %q", fieldName, id)
	}
	if strings.Count(id, ":") > 1 {
		return fmt.Errorf("%s is not a valid registry identifier: multiple ':' separators in %q", fieldName, id)
	}
	ns := id[:idx]
	name := id[idx+1:]
	if len(ns) == 0 {
		return fmt.Errorf("%s is not a valid registry identifier: empty namespace in %q", fieldName, id)
	}
	if len(name) == 0 {
		return fmt.Errorf("%s is not a valid registry identifier: empty name in %q", fieldName, id)
	}
	if err := validateIDCharacters(ns, fieldName+" namespace"); err != nil {
		return err
	}
	if err := validateIDCharacters(name, fieldName+" name"); err != nil {
		return err
	}
	return nil
}

func validateIDCharacters(s string, fieldName string) error {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.') {
			return fmt.Errorf("%s contains invalid character %q at byte %d", fieldName, c, i)
		}
	}
	return nil
}
