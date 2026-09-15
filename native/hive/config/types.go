// SPDX-License-Identifier: MIT

package config

import (
	"encoding/json"
	"errors"
)

const (
	// ConfigFileName is the filename of the persistent machine configuration document.
	ConfigFileName = "config.json"

	// LockFileName is the filename of the exclusive companion lock file.
	LockFileName = ".config.lock"

	// CurrentVersion is the required schema version for machine configuration documents.
	CurrentVersion = 1

	// MaxDocumentBytes is the maximum allowed size of a configuration document (4 MiB).
	MaxDocumentBytes = 4 * 1024 * 1024

	// MaxWorkspaces is the maximum number of workspace entries allowed in a document.
	MaxWorkspaces = 4096

	// MaxIDBytes is the maximum allowed byte length of a WorkspaceID (160 bytes).
	MaxIDBytes = 160

	// MaxHiveSeeds is the maximum number of seed join addresses.
	MaxHiveSeeds = 16

	// MaxHivePeers is the maximum number of authoritative Hive peer keys.
	MaxHivePeers = 256

	// MaxPathBytes is the maximum allowed byte length of a file path (4096 bytes).
	MaxPathBytes = 4096
)

// HiveMode selects a local-only configuration or an explicitly joined runtime.
type HiveMode string

const (
	HiveModeLocal  HiveMode = "local"
	HiveModeJoined HiveMode = "joined"
)

// Secret holds a serialized credential and redacts it in formatted output.
// JSON serialization remains intentional because the private config file owns
// persistence for these values.
type Secret string

func (Secret) String() string                 { return "[REDACTED]" }
func (Secret) GoString() string               { return "config.Secret{[REDACTED]}" }
func (s Secret) MarshalJSON() ([]byte, error) { return json.Marshal(string(s)) }

var (
	// ErrConflict is returned when expectedRevision does not match the stored revision.
	ErrConflict = errors.New("config: revision conflict")

	// ErrMalformedDocument is returned when a document is malformed, corrupt, or violates schema bounds.
	ErrMalformedDocument = errors.New("config: malformed document")

	// ErrRevisionOverflow is returned when the document revision cannot be incremented without overflowing uint64.
	ErrRevisionOverflow = errors.New("config: revision overflow")
)

// Document represents the typed version 1 machine configuration.
type Document struct {
	Version    int                 `json:"version"`
	Revision   uint64              `json:"revision"`
	Hive       HiveProfile         `json:"hive"`
	Workspaces []WorkspaceLocation `json:"workspaces"`
}

// HiveProfile is the versioned local or joined runtime profile. In local mode
// only Mode is serialized. Joined profiles keep credentials in this owner-only
// machine file; callers should never log this value.
type HiveProfile struct {
	Mode                       HiveMode          `json:"-"`
	HiveID                     string            `json:"-"`
	NodeID                     string            `json:"-"`
	Seeds                      []string          `json:"-"`
	MembershipSecret           Secret            `json:"-"`
	InternodePrivateKey        Secret            `json:"-"`
	PeerPublicKeys             map[string]string `json:"-"`
	TLSCertPath                string            `json:"-"`
	TLSKeyPath                 string            `json:"-"`
	TLSCAPath                  string            `json:"-"`
	MembershipBindAddress      string            `json:"-"`
	MembershipBindPort         uint16            `json:"-"`
	MembershipAdvertiseAddress string            `json:"-"`
	MembershipAdvertisePort    uint16            `json:"-"`
	InternodeBindAddress       string            `json:"-"`
	InternodeBindPort          uint16            `json:"-"`
	InternodeAdvertiseAddress  string            `json:"-"`
	InternodeAdvertisePort     uint16            `json:"-"`
}

// MarshalJSON keeps the local profile minimal and omits only optional advertise
// endpoint pairs. Required joined fields are always emitted.
func (h HiveProfile) MarshalJSON() ([]byte, error) {
	if err := validateHiveProfile(h); err != nil {
		return nil, err
	}
	if h.Mode == "local" {
		return json.Marshal(struct {
			Mode HiveMode `json:"mode"`
		}{Mode: h.Mode})
	}
	type joinedJSON struct {
		Mode                       HiveMode          `json:"mode"`
		HiveID                     string            `json:"hive_id"`
		NodeID                     string            `json:"node_id"`
		Seeds                      []string          `json:"seeds"`
		MembershipSecret           string            `json:"membership_secret"`
		InternodePrivateKey        string            `json:"internode_private_key"`
		PeerPublicKeys             map[string]string `json:"peer_public_keys"`
		TLSCertPath                string            `json:"tls_cert_path"`
		TLSKeyPath                 string            `json:"tls_key_path"`
		TLSCAPath                  string            `json:"tls_ca_path"`
		MembershipBindAddress      string            `json:"membership_bind_address"`
		MembershipBindPort         uint16            `json:"membership_bind_port"`
		MembershipAdvertiseAddress string            `json:"membership_advertise_address,omitempty"`
		MembershipAdvertisePort    uint16            `json:"membership_advertise_port,omitempty"`
		InternodeBindAddress       string            `json:"internode_bind_address"`
		InternodeBindPort          uint16            `json:"internode_bind_port"`
		InternodeAdvertiseAddress  string            `json:"internode_advertise_address,omitempty"`
		InternodeAdvertisePort     uint16            `json:"internode_advertise_port,omitempty"`
	}
	return json.Marshal(joinedJSON{
		Mode: h.Mode, HiveID: h.HiveID, NodeID: h.NodeID, Seeds: h.Seeds,
		MembershipSecret: string(h.MembershipSecret), InternodePrivateKey: string(h.InternodePrivateKey),
		PeerPublicKeys: h.PeerPublicKeys, TLSCertPath: h.TLSCertPath, TLSKeyPath: h.TLSKeyPath,
		TLSCAPath: h.TLSCAPath, MembershipBindAddress: h.MembershipBindAddress,
		MembershipBindPort: h.MembershipBindPort, MembershipAdvertiseAddress: h.MembershipAdvertiseAddress,
		MembershipAdvertisePort: h.MembershipAdvertisePort, InternodeBindAddress: h.InternodeBindAddress,
		InternodeBindPort: h.InternodeBindPort, InternodeAdvertiseAddress: h.InternodeAdvertiseAddress,
		InternodeAdvertisePort: h.InternodeAdvertisePort,
	})
}

// String and GoString redact the profile's membership and private identity keys.
func (HiveProfile) String() string   { return "HiveProfile{credentials:[REDACTED]}" }
func (HiveProfile) GoString() string { return "config.HiveProfile{credentials:[REDACTED]}" }

func (Document) String() string   { return "Document{configuration:[REDACTED]}" }
func (Document) GoString() string { return "config.Document{configuration:[REDACTED]}" }

// WorkspaceLocation records the mapping between an opaque workspace ID and its
// native filesystem paths. One WorkspaceID may have multiple ProjectDirs, but
// all its entries must agree on RuntimeStateDir. Each ProjectDir maps at most once.
// Several workspace IDs may share one runtime state directory. This is a
// location hint for registry/deployment storage, not a workspace database grant.
type WorkspaceLocation struct {
	WorkspaceID     string `json:"workspace_id"`
	ProjectDir      string `json:"project_dir"`
	RuntimeStateDir string `json:"runtime_state_dir"`
}

// Clone returns a deep copy of the document with an independent Workspaces slice.
func (d Document) Clone() Document {
	out := d
	out.Hive = d.Hive.Clone()
	if d.Workspaces != nil {
		out.Workspaces = make([]WorkspaceLocation, len(d.Workspaces))
		copy(out.Workspaces, d.Workspaces)
	} else {
		out.Workspaces = []WorkspaceLocation{}
	}
	return out
}

// Clone returns a profile with independent slice and map storage.
func (h HiveProfile) Clone() HiveProfile {
	out := h
	if h.Seeds != nil {
		out.Seeds = append([]string{}, h.Seeds...)
	}
	if h.PeerPublicKeys != nil {
		out.PeerPublicKeys = make(map[string]string, len(h.PeerPublicKeys))
		for id, key := range h.PeerPublicKeys {
			out.PeerPublicKeys[id] = key
		}
	}
	return out
}

// LocalHiveProfile creates the fresh-install profile.
func LocalHiveProfile() HiveProfile { return HiveProfile{Mode: HiveModeLocal} }
