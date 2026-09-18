// SPDX-License-Identifier: MIT

package config

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func testJoinedProfile() HiveProfile {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	private := ed25519.NewKeyFromSeed(seed)
	return HiveProfile{
		Mode: "joined", HiveID: "hive-example", NodeID: "node-a",
		Seeds:               []string{"seed.example:4400"},
		MembershipSecret:    Secret(base64.StdEncoding.EncodeToString([]byte("01234567890123456789012345678901"))),
		InternodePrivateKey: Secret(base64.StdEncoding.EncodeToString(private)),
		PeerPublicKeys:      map[string]string{"node-a": base64.StdEncoding.EncodeToString(private.Public().(ed25519.PublicKey))},
		TLSCertPath:         "/etc/bee/tls/cert.pem", TLSKeyPath: "/etc/bee/tls/key.pem", TLSCAPath: "/etc/bee/tls/ca.pem",
		MembershipBindAddress: "0.0.0.0", MembershipBindPort: 0,
		MembershipAdvertiseAddress: "bee.example", MembershipAdvertisePort: 4401,
		InternodeBindAddress: "::", InternodeBindPort: 5500,
		InternodeAdvertiseAddress: "2001:db8::5", InternodeAdvertisePort: 5500,
	}
}

func TestHiveProfileRoundtripAndLocalShape(t *testing.T) {
	doc := Document{Version: CurrentVersion, Revision: 1, Hive: testJoinedProfile(), Workspaces: []WorkspaceLocation{}}
	encoded, err := marshalDocument(doc)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Decode(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if got.Hive.Mode != "joined" || got.Hive.NodeID != "node-a" || got.Hive.MembershipAdvertisePort != 4401 {
		t.Fatalf("joined profile did not roundtrip: %#v", got.Hive)
	}

	local, err := marshalDocument(Document{Version: CurrentVersion, Revision: 1, Hive: LocalHiveProfile(), Workspaces: []WorkspaceLocation{}})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(local), `"mode": "local"`) {
		t.Fatalf("local profile serialized unexpected shape: %s", local)
	}
	if _, err := Decode([]byte(`{"version":1,"revision":1,"hive":{"mode":"local","hive_id":"x"},"workspaces":[]}`)); err == nil {
		t.Fatal("local profile accepted joined field")
	}
}

func TestJoinedProfileStrictJSONFields(t *testing.T) {
	doc := Document{Version: CurrentVersion, Revision: 1, Hive: testJoinedProfile(), Workspaces: []WorkspaceLocation{}}
	encoded, err := marshalDocument(doc)
	if err != nil {
		t.Fatal(err)
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, encoded); err != nil {
		t.Fatal(err)
	}
	valid := compact.String()
	cases := map[string]string{
		"unknown":         strings.Replace(valid, `"mode":"joined"`, `"mode":"joined","extra":1`, 1),
		"duplicate":       strings.Replace(valid, `"mode":"joined"`, `"mode":"joined","mode":"joined"`, 1),
		"case alias":      strings.Replace(valid, `"mode":"joined"`, `"Mode":"joined"`, 1),
		"null credential": strings.Replace(valid, `"membership_secret":"`+string(doc.Hive.MembershipSecret)+`"`, `"membership_secret":null`, 1),
		"missing node id": strings.Replace(valid, `"node_id":"node-a",`, "", 1),
	}
	peerKey := doc.Hive.PeerPublicKeys["node-a"]
	peerEntry := `"node-a":"` + peerKey + `"`
	cases["duplicate peer"] = strings.Replace(valid, `"peer_public_keys":{`+peerEntry+`}`, `"peer_public_keys":{`+peerEntry+`,`+peerEntry+`}`, 1)
	for name, payload := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode([]byte(payload)); err == nil {
				t.Fatal("malformed joined profile was accepted")
			}
		})
	}
}

func TestJoinedProfileValidationAndRedaction(t *testing.T) {
	base := testJoinedProfile()
	tests := map[string]func(*HiveProfile){
		"bad membership key size": func(h *HiveProfile) { h.MembershipSecret = Secret("short") },
		"bad private key": func(h *HiveProfile) {
			h.InternodePrivateKey = Secret(base64.StdEncoding.EncodeToString(make([]byte, ed25519.PrivateKeySize)))
		},
		"local key mismatch": func(h *HiveProfile) {
			h.PeerPublicKeys["node-a"] = base64.StdEncoding.EncodeToString(make([]byte, ed25519.PublicKeySize))
		},
		"missing local peer": func(h *HiveProfile) { h.PeerPublicKeys = map[string]string{} },
		"bad seed address":   func(h *HiveProfile) { h.Seeds = []string{"bad:host:port"} },
		"seed port zero":     func(h *HiveProfile) { h.Seeds = []string{"seed.example:0"} },
		"unclean TLS path":   func(h *HiveProfile) { h.TLSKeyPath = "/etc/bee/../key.pem" },
		"advertise mismatch": func(h *HiveProfile) { h.MembershipBindPort = 4400 },
		"advertise zero":     func(h *HiveProfile) { h.MembershipAdvertisePort = 0 },
		"wildcard advertise": func(h *HiveProfile) { h.InternodeAdvertiseAddress = "0.0.0.0" },
		"duplicate seeds":    func(h *HiveProfile) { h.Seeds = []string{"seed.example:4400", "seed.example:4400"} },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			profile := base.Clone()
			mutate(&profile)
			if err := validateHiveProfile(profile); err == nil {
				t.Fatal("invalid profile was accepted")
			}
		})
	}
	formatted := fmt.Sprintf("%+v %#v", base, base)
	if strings.Contains(formatted, string(base.MembershipSecret)) || strings.Contains(formatted, string(base.InternodePrivateKey)) {
		t.Fatal("profile formatting exposed credentials")
	}
	formattedSecret := fmt.Sprintf("%v %q %#v", base.MembershipSecret, base.MembershipSecret, base.MembershipSecret)
	if strings.Contains(formattedSecret, string(base.MembershipSecret)) {
		t.Fatal("secret formatting exposed credential")
	}
	docFormatted := fmt.Sprintf("%+v %#v", Document{Hive: base}, Document{Hive: base})
	if strings.Contains(docFormatted, string(base.MembershipSecret)) || strings.Contains(docFormatted, string(base.InternodePrivateKey)) {
		t.Fatal("document formatting exposed credentials")
	}
}

func TestProfileCloneDoesNotAliasPeerMapOrSeeds(t *testing.T) {
	original := testJoinedProfile()
	clone := original.Clone()
	clone.Seeds[0] = "other.example:4400"
	clone.PeerPublicKeys["node-a"] = "changed"
	if original.Seeds[0] == clone.Seeds[0] || original.PeerPublicKeys["node-a"] == clone.PeerPublicKeys["node-a"] {
		t.Fatal("profile clone aliases mutable data")
	}
}

func TestHiveProfileMarshalJSONUsesOnlyProfileFields(t *testing.T) {
	data, err := json.Marshal(LocalHiveProfile())
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != `{"mode":"local"}` {
		t.Fatalf("unexpected local JSON: %s", data)
	}
}
