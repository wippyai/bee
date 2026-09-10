// SPDX-License-Identifier: MIT
package service

import (
	"errors"
	"slices"
	"time"

	"github.com/wippyai/runtime/api/security"
)

const DesktopHostPolicy = "bee.hive.desktop:host_policy"
const desktopTimeFormat = "2006-01-02T15:04:05.000Z"

// DesktopConfig is an explicit host grant for the optional retained desktop
// bridge. It is never read from activation metadata or a remote request.
// AllowedNodes are enrolled identities, not discovered names or local flags.
type DesktopConfig struct {
	// ClientPolicy is an unpublished, immutable host-selected policy. It is
	// installed only in the supervisor's child scope, never exported to Lua.
	ClientPolicy security.Policy
	Execution    string
	ExpiresAt    time.Time
	AllowedNodes []string
	Application  string
}

func (d *DesktopConfig) clone() *DesktopConfig {
	if d == nil {
		return nil
	}
	result := *d
	result.AllowedNodes = slices.Clone(d.AllowedNodes)
	return &result
}
func (d *DesktopConfig) validate() error {
	if len(d.Execution) != 32 {
		return errors.New("desktop execution must be 32 lowercase hexadecimal characters")
	}
	for _, c := range d.Execution {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return errors.New("invalid desktop execution identity")
		}
	}
	if d.ExpiresAt.IsZero() || !time.Now().Before(d.ExpiresAt) || d.ExpiresAt.Year() > 9999 || d.ExpiresAt.Year() < 1 || d.ExpiresAt.Nanosecond()%int(time.Millisecond) != 0 {
		return errors.New("desktop expiry must be a future timestamp with millisecond precision")
	}
	if len(d.AllowedNodes) == 0 && d.ClientPolicy == nil {
		return errors.New("desktop admission requires explicit allowed nodes")
	}
	if err := validateConfiguredNodes(d.AllowedNodes); err != nil {
		return err
	}
	if d.Application != "" {
		return validateRegistryID(d.Application, "desktop application")
	}
	return nil
}
func (d *DesktopConfig) input() map[string]any {
	result := map[string]any{"execution": d.Execution, "expires_at": d.ExpiresAt.UTC().Format(desktopTimeFormat), "allowed_nodes": append([]string{}, d.AllowedNodes...)}
	if d.ClientPolicy != nil {
		result["local_clients"] = true
	}
	if d.Application != "" {
		result["application"] = d.Application
	}
	return result
}
