// SPDX-License-Identifier: MIT

package config

import (
	"crypto/ed25519"
	"encoding/base64"
	"fmt"
	"net"
	"net/netip"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

func validateDocument(doc Document, fromDisk bool) error {
	if len(doc.Workspaces) > MaxWorkspaces {
		return fmt.Errorf("%w: workspace entries limit exceeded", ErrMalformedDocument)
	}
	if doc.Version != CurrentVersion {
		return fmt.Errorf("%w: unsupported version", ErrMalformedDocument)
	}
	if fromDisk && doc.Revision == 0 {
		return fmt.Errorf("%w: revision must be positive on disk", ErrMalformedDocument)
	}
	if err := validateHiveProfile(doc.Hive); err != nil {
		return err
	}
	for _, loc := range doc.Workspaces {
		if err := validateID(loc.WorkspaceID, "workspace_id"); err != nil {
			return err
		}
		if err := validatePath(loc.ProjectDir, "project_dir"); err != nil {
			return err
		}
		if err := validatePath(loc.RuntimeStateDir, "runtime_state_dir"); err != nil {
			return err
		}
	}
	return validateWorkspacesInvariants(doc.Workspaces)
}

func validateID(id, fieldName string) error {
	if len(id) == 0 {
		return fmt.Errorf("%w: %s cannot be empty", ErrMalformedDocument, fieldName)
	}
	if len(id) > MaxIDBytes {
		return fmt.Errorf("%w: %s exceeds maximum length", ErrMalformedDocument, fieldName)
	}
	if !utf8.ValidString(id) {
		return fmt.Errorf("%w: %s contains invalid UTF-8", ErrMalformedDocument, fieldName)
	}
	for _, r := range id {
		if unicode.IsControl(r) {
			return fmt.Errorf("%w: %s contains control character", ErrMalformedDocument, fieldName)
		}
	}
	return nil
}

func validateHiveProfile(h HiveProfile) error {
	if h.Mode == "local" {
		if h.HiveID != "" || h.NodeID != "" || len(h.Seeds) != 0 || h.MembershipSecret != "" ||
			h.InternodePrivateKey != "" || len(h.PeerPublicKeys) != 0 || h.TLSCertPath != "" ||
			h.TLSKeyPath != "" || h.TLSCAPath != "" || h.MembershipBindAddress != "" ||
			h.MembershipBindPort != 0 || h.MembershipAdvertiseAddress != "" || h.MembershipAdvertisePort != 0 ||
			h.InternodeBindAddress != "" || h.InternodeBindPort != 0 || h.InternodeAdvertiseAddress != "" ||
			h.InternodeAdvertisePort != 0 {
			return fmt.Errorf("%w: local hive profile has joined fields", ErrMalformedDocument)
		}
		return nil
	}
	if h.Mode != "joined" {
		return fmt.Errorf("%w: invalid hive mode", ErrMalformedDocument)
	}
	if err := validateID(h.HiveID, "hive_id"); err != nil {
		return err
	}
	if err := validateID(h.NodeID, "node_id"); err != nil {
		return err
	}
	if len(h.Seeds) == 0 || len(h.Seeds) > MaxHiveSeeds {
		return fmt.Errorf("%w: invalid hive seed count", ErrMalformedDocument)
	}
	seenSeeds := make(map[string]bool, len(h.Seeds))
	for _, seed := range h.Seeds {
		if err := validateSeedAddress(seed); err != nil {
			return err
		}
		if seenSeeds[seed] {
			return fmt.Errorf("%w: duplicate hive seed address", ErrMalformedDocument)
		}
		seenSeeds[seed] = true
	}
	if _, err := decodeKey(string(h.MembershipSecret), 32); err != nil {
		return fmt.Errorf("%w: invalid membership secret", ErrMalformedDocument)
	}
	private, err := decodeKey(string(h.InternodePrivateKey), ed25519.PrivateKeySize)
	if err != nil {
		return fmt.Errorf("%w: invalid internode private identity", ErrMalformedDocument)
	}
	if derived := ed25519.NewKeyFromSeed(private[:ed25519.SeedSize]); !derived.Equal(ed25519.PrivateKey(private)) {
		return fmt.Errorf("%w: invalid internode private identity", ErrMalformedDocument)
	}
	if len(h.PeerPublicKeys) == 0 || len(h.PeerPublicKeys) > MaxHivePeers {
		return fmt.Errorf("%w: invalid hive peer count", ErrMalformedDocument)
	}
	localKey, present := h.PeerPublicKeys[h.NodeID]
	if !present {
		return fmt.Errorf("%w: local node missing from peer key map", ErrMalformedDocument)
	}
	localPublic, err := decodeKey(localKey, ed25519.PublicKeySize)
	if err != nil || !ed25519.PublicKey(private[ed25519.SeedSize:]).Equal(ed25519.PublicKey(localPublic)) {
		return fmt.Errorf("%w: local internode key mismatch", ErrMalformedDocument)
	}
	seenKeys := make(map[string]bool, len(h.PeerPublicKeys))
	for nodeID, encoded := range h.PeerPublicKeys {
		if err := validateID(nodeID, "peer node_id"); err != nil {
			return err
		}
		key, err := decodeKey(encoded, ed25519.PublicKeySize)
		if err != nil {
			return fmt.Errorf("%w: invalid peer public key", ErrMalformedDocument)
		}
		keyID := string(key)
		if seenKeys[keyID] {
			return fmt.Errorf("%w: duplicate peer public key", ErrMalformedDocument)
		}
		seenKeys[keyID] = true
	}
	for field, path := range map[string]string{
		"tls_cert_path": h.TLSCertPath, "tls_key_path": h.TLSKeyPath, "tls_ca_path": h.TLSCAPath,
	} {
		if err := validatePath(path, field); err != nil {
			return err
		}
	}
	if err := validateBindAddress(h.MembershipBindAddress); err != nil {
		return fmt.Errorf("%w: invalid membership bind address", ErrMalformedDocument)
	}
	if err := validateBindAddress(h.InternodeBindAddress); err != nil {
		return fmt.Errorf("%w: invalid internode bind address", ErrMalformedDocument)
	}
	if err := validateAdvertiseEndpoint(h.MembershipBindPort, h.MembershipAdvertiseAddress, h.MembershipAdvertisePort); err != nil {
		return fmt.Errorf("%w: invalid membership advertise endpoint", ErrMalformedDocument)
	}
	if err := validateAdvertiseEndpoint(h.InternodeBindPort, h.InternodeAdvertiseAddress, h.InternodeAdvertisePort); err != nil {
		return fmt.Errorf("%w: invalid internode advertise endpoint", ErrMalformedDocument)
	}
	return nil
}

func decodeKey(encoded string, size int) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(decoded) != size || base64.StdEncoding.EncodeToString(decoded) != encoded {
		return nil, fmt.Errorf("invalid key encoding")
	}
	return decoded, nil
}

func validateSeedAddress(address string) error {
	if len(address) > 512 {
		return fmt.Errorf("%w: invalid seed address", ErrMalformedDocument)
	}
	host, portText, err := net.SplitHostPort(address)
	if err != nil || host == "" {
		return fmt.Errorf("%w: invalid seed address", ErrMalformedDocument)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("%w: invalid seed port", ErrMalformedDocument)
	}
	if err := validateHost(host, false); err != nil {
		return err
	}
	return nil
}

func validateBindAddress(host string) error { return validateHost(host, true) }

func validateAdvertiseEndpoint(bindPort uint16, host string, port uint16) error {
	if host == "" && port == 0 {
		return nil
	}
	if host == "" || port == 0 || (bindPort != 0 && bindPort != port) {
		return fmt.Errorf("invalid advertise endpoint")
	}
	return validateHost(host, false)
}

func validateHost(host string, allowWildcard bool) error {
	if host == "" {
		if allowWildcard {
			return nil
		}
		return fmt.Errorf("empty host")
	}
	if len(host) > 253 || !utf8.ValidString(host) || strings.ContainsAny(host, "[]%/\\") {
		return fmt.Errorf("invalid host")
	}
	for _, r := range host {
		if unicode.IsControl(r) || unicode.IsSpace(r) {
			return fmt.Errorf("invalid host")
		}
	}
	if addr, err := netip.ParseAddr(host); err == nil {
		if !allowWildcard && addr.IsUnspecified() {
			return fmt.Errorf("unspecified advertise host")
		}
		return nil
	}
	if strings.Contains(host, ":") || (looksLikeIPv4(host)) {
		return fmt.Errorf("invalid IP address")
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return fmt.Errorf("invalid DNS host")
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') && r != '-' {
				return fmt.Errorf("invalid DNS host")
			}
		}
	}
	return nil
}

func looksLikeIPv4(host string) bool {
	if !strings.Contains(host, ".") {
		return false
	}
	for _, r := range host {
		if (r < '0' || r > '9') && r != '.' {
			return false
		}
	}
	return true
}

func validatePath(path, fieldName string) error {
	if len(path) == 0 {
		return fmt.Errorf("%w: %s cannot be empty", ErrMalformedDocument, fieldName)
	}
	if len(path) > MaxPathBytes {
		return fmt.Errorf("%w: %s exceeds maximum length", ErrMalformedDocument, fieldName)
	}
	if !utf8.ValidString(path) {
		return fmt.Errorf("%w: %s contains invalid UTF-8", ErrMalformedDocument, fieldName)
	}
	for _, r := range path {
		if unicode.IsControl(r) {
			return fmt.Errorf("%w: %s contains control character", ErrMalformedDocument, fieldName)
		}
	}
	if !filepath.IsAbs(path) {
		return fmt.Errorf("%w: %s must be absolute path", ErrMalformedDocument, fieldName)
	}
	if filepath.Clean(path) != path {
		return fmt.Errorf("%w: %s must be canonical cleaned path", ErrMalformedDocument, fieldName)
	}
	return nil
}

func validateWorkspacesInvariants(workspaces []WorkspaceLocation) error {
	if len(workspaces) > MaxWorkspaces {
		return fmt.Errorf("%w: workspace entries limit exceeded", ErrMalformedDocument)
	}
	seenProjectDir := make(map[string]bool, len(workspaces))
	workspaceToState := make(map[string]string, len(workspaces))

	for _, loc := range workspaces {
		// Each ProjectDir maps once
		if seenProjectDir[loc.ProjectDir] {
			return fmt.Errorf("%w: duplicate project directory", ErrMalformedDocument)
		}
		seenProjectDir[loc.ProjectDir] = true

		// One WorkspaceID may have multiple ProjectDirs, but all its entries must agree on RuntimeStateDir
		if existingState, ok := workspaceToState[loc.WorkspaceID]; ok {
			if existingState != loc.RuntimeStateDir {
				return fmt.Errorf("%w: inconsistent state directory for workspace", ErrMalformedDocument)
			}
		} else {
			workspaceToState[loc.WorkspaceID] = loc.RuntimeStateDir
		}

	}
	return nil
}
