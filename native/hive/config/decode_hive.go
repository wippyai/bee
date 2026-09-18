// SPDX-License-Identifier: MIT

package config

import (
	"encoding/json"
	"fmt"
	"math"
	"strconv"
	"strings"
)

func decodeHiveProfile(dec *json.Decoder) (HiveProfile, error) {
	tok, err := dec.Token()
	if err != nil {
		return HiveProfile{}, malformed("invalid JSON syntax")
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return HiveProfile{}, malformed("hive must be an object")
	}

	h := HiveProfile{}
	seen := make(map[string]bool, 20)
	for dec.More() {
		tok, err = dec.Token()
		if err != nil {
			return HiveProfile{}, malformed("invalid JSON syntax")
		}
		key, ok := tok.(string)
		if !ok {
			return HiveProfile{}, malformed("invalid hive field")
		}
		if seen[key] {
			return HiveProfile{}, malformed("duplicate hive field")
		}
		seen[key] = true
		switch key {
		case "mode":
			var mode string
			mode, err = decodeHiveString(dec, key)
			h.Mode = HiveMode(mode)
		case "hive_id":
			h.HiveID, err = decodeHiveString(dec, key)
		case "node_id":
			h.NodeID, err = decodeHiveString(dec, key)
		case "seeds":
			h.Seeds, err = decodeHiveStrings(dec, key)
		case "membership_secret":
			var value string
			value, err = decodeHiveString(dec, key)
			h.MembershipSecret = Secret(value)
		case "internode_private_key":
			var value string
			value, err = decodeHiveString(dec, key)
			h.InternodePrivateKey = Secret(value)
		case "peer_public_keys":
			h.PeerPublicKeys, err = decodeHiveKeyMap(dec)
		case "tls_cert_path":
			h.TLSCertPath, err = decodeHiveString(dec, key)
		case "tls_key_path":
			h.TLSKeyPath, err = decodeHiveString(dec, key)
		case "tls_ca_path":
			h.TLSCAPath, err = decodeHiveString(dec, key)
		case "membership_bind_address":
			h.MembershipBindAddress, err = decodeHiveString(dec, key)
		case "membership_bind_port":
			h.MembershipBindPort, err = decodeHivePort(dec, key)
		case "membership_advertise_address":
			h.MembershipAdvertiseAddress, err = decodeHiveString(dec, key)
		case "membership_advertise_port":
			h.MembershipAdvertisePort, err = decodeHivePort(dec, key)
		case "internode_bind_address":
			h.InternodeBindAddress, err = decodeHiveString(dec, key)
		case "internode_bind_port":
			h.InternodeBindPort, err = decodeHivePort(dec, key)
		case "internode_advertise_address":
			h.InternodeAdvertiseAddress, err = decodeHiveString(dec, key)
		case "internode_advertise_port":
			h.InternodeAdvertisePort, err = decodeHivePort(dec, key)
		default:
			return HiveProfile{}, malformed("unknown hive field")
		}
		if err != nil {
			return HiveProfile{}, err
		}
	}
	tok, err = dec.Token()
	if err != nil || tok != json.Delim('}') {
		return HiveProfile{}, malformed("expected end of hive object")
	}
	if !seen["mode"] {
		return HiveProfile{}, malformed("missing hive mode")
	}
	if h.Mode == "local" {
		if len(seen) != 1 {
			return HiveProfile{}, malformed("local hive profile has joined fields")
		}
		return h, nil
	}
	if h.Mode != "joined" {
		return HiveProfile{}, malformed("invalid hive mode")
	}
	for _, field := range []string{
		"hive_id", "node_id", "seeds", "membership_secret", "internode_private_key", "peer_public_keys",
		"tls_cert_path", "tls_key_path", "tls_ca_path", "membership_bind_address", "membership_bind_port",
		"internode_bind_address", "internode_bind_port",
	} {
		if !seen[field] {
			return HiveProfile{}, malformed("missing joined hive field")
		}
	}
	for _, pair := range [][2]string{
		{"membership_advertise_address", "membership_advertise_port"},
		{"internode_advertise_address", "internode_advertise_port"},
	} {
		if seen[pair[0]] != seen[pair[1]] {
			return HiveProfile{}, malformed("incomplete advertise endpoint")
		}
		if seen[pair[0]] {
			var address string
			var port uint16
			if pair[0] == "membership_advertise_address" {
				address, port = h.MembershipAdvertiseAddress, h.MembershipAdvertisePort
			} else {
				address, port = h.InternodeAdvertiseAddress, h.InternodeAdvertisePort
			}
			if address == "" || port == 0 {
				return HiveProfile{}, malformed("invalid advertise endpoint")
			}
		}
	}
	return h, nil
}

func decodeHiveString(dec *json.Decoder, field string) (string, error) {
	tok, err := dec.Token()
	if err != nil {
		return "", malformed("invalid JSON syntax")
	}
	s, ok := tok.(string)
	if !ok {
		return "", malformed("invalid hive field type")
	}
	return s, nil
}

func decodeHivePort(dec *json.Decoder, field string) (uint16, error) {
	tok, err := dec.Token()
	if err != nil {
		return 0, malformed("invalid JSON syntax")
	}
	num, ok := tok.(json.Number)
	if !ok {
		return 0, malformed("invalid hive port type")
	}
	s := string(num)
	if strings.ContainsAny(s, ".eE-+") {
		return 0, malformed("invalid hive port")
	}
	n, err := strconv.ParseUint(s, 10, 16)
	if err != nil || n > math.MaxUint16 {
		return 0, malformed("invalid hive port")
	}
	return uint16(n), nil
}

func decodeHiveStrings(dec *json.Decoder, field string) ([]string, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, malformed("invalid JSON syntax")
	}
	if tok == nil {
		return nil, malformed("null hive field")
	}
	if tok != json.Delim('[') {
		return nil, malformed("invalid hive array")
	}
	out := make([]string, 0)
	for dec.More() {
		if len(out) >= MaxHiveSeeds {
			return nil, malformed("hive seed limit exceeded")
		}
		item, err := dec.Token()
		if err != nil {
			return nil, malformed("invalid JSON syntax")
		}
		value, ok := item.(string)
		if !ok {
			return nil, malformed("invalid hive seed")
		}
		out = append(out, value)
	}
	tok, err = dec.Token()
	if err != nil || tok != json.Delim(']') {
		return nil, malformed("expected end of hive array")
	}
	return out, nil
}

func decodeHiveKeyMap(dec *json.Decoder) (map[string]string, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, malformed("invalid JSON syntax")
	}
	if tok == nil {
		return nil, malformed("null hive field")
	}
	if tok != json.Delim('{') {
		return nil, malformed("invalid peer key map")
	}
	out := make(map[string]string)
	for dec.More() {
		tok, err = dec.Token()
		if err != nil {
			return nil, malformed("invalid JSON syntax")
		}
		id, ok := tok.(string)
		if !ok {
			return nil, malformed("invalid peer key id")
		}
		if _, exists := out[id]; exists {
			return nil, malformed("duplicate peer key id")
		}
		value, err := dec.Token()
		if err != nil {
			return nil, malformed("invalid JSON syntax")
		}
		key, ok := value.(string)
		if !ok {
			return nil, malformed("invalid peer public key")
		}
		out[id] = key
		if len(out) > MaxHivePeers {
			return nil, malformed("hive peer limit exceeded")
		}
	}
	tok, err = dec.Token()
	if err != nil || tok != json.Delim('}') {
		return nil, malformed("expected end of peer key map")
	}
	return out, nil
}

func malformed(reason string) error { return fmt.Errorf("%w: %s", ErrMalformedDocument, reason) }
