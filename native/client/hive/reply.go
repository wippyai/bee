//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"
	"unicode/utf8"
)

type Identity struct {
	Operation string `json:"operation_ref"`
	Key       string `json:"idempotency_key"`
}
type Fault struct {
	Code      string    `json:"code"`
	Message   string    `json:"message"`
	Retryable bool      `json:"retryable"`
	Identity  *Identity `json:"identity,omitempty"`
}
type Grant struct {
	ID      string `json:"grant_id"`
	Owner   Owner  `json:"issuer_owner_ref"`
	Epoch   int64  `json:"authorization_epoch"`
	Expires string `json:"expires_at"`
}
type Reply struct {
	ID       string
	OK       bool
	Fault    *Fault
	Value    json.RawMessage
	Grants   []Grant
	lifetime <-chan struct{}
}

func identifier(s string) bool {
	if s == "" || len(s) > 160 || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 32 || r == 127 {
			return false
		}
	}
	return true
}

// JSON objects reject duplicate keys recursively, including inside operation
// values. RawMessage fields must not create a bypass around the envelope check.
func uniqueJSON(raw []byte) bool {
	if len(raw) == 0 || len(raw) > maxBytes || !utf8.Valid(raw) {
		return false
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value func(int) bool
	value = func(depth int) bool {
		if depth > 32 {
			return false
		}
		token, err := decoder.Token()
		if err != nil {
			return false
		}
		delim, container := token.(json.Delim)
		if !container {
			return true
		}
		switch delim {
		case '{':
			keys := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				name, ok := key.(string)
				if err != nil || !ok || keys[name] {
					return false
				}
				keys[name] = true
				if !value(depth + 1) {
					return false
				}
			}
			end, err := decoder.Token()
			return err == nil && end == json.Delim('}')
		case '[':
			for decoder.More() {
				if !value(depth + 1) {
					return false
				}
			}
			end, err := decoder.Token()
			return err == nil && end == json.Delim(']')
		default:
			return false
		}
	}
	if !value(0) {
		return false
	}
	_, err := decoder.Token()
	return err == io.EOF
}
func object(raw []byte) bool {
	if len(raw) > maxBytes {
		return false
	}
	body := bytes.TrimSpace(raw)
	return len(body) > 0 && body[0] == '{' && uniqueJSON(body)
}
func strict(raw []byte, into any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	return d.Decode(into)
}
func present(raw json.RawMessage) bool {
	return len(raw) > 0 && !bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}
func canonicalTime(s string) bool {
	parsed, err := time.Parse("2006-01-02T15:04:05.000Z", s)
	return err == nil && parsed.UTC().Format("2006-01-02T15:04:05.000Z") == s
}
func decodeReply(raw []byte) (Reply, error) {
	invalid := errors.New("invalid Hive reply envelope")
	if !allowedFields(raw, "protocol_revision", "request_id", "ok", "error", "value", "grants") {
		return Reply{}, invalid
	}
	var wire struct {
		Revision string          `json:"protocol_revision"`
		ID       string          `json:"request_id"`
		OK       *bool           `json:"ok"`
		Error    json.RawMessage `json:"error"`
		Value    json.RawMessage `json:"value"`
		Grants   json.RawMessage `json:"grants"`
	}
	if strict(raw, &wire) != nil || wire.Revision != Revision || !identifier(wire.ID) || wire.OK == nil ||
		(*wire.OK == present(wire.Error)) || (!*wire.OK && present(wire.Value)) {
		return Reply{}, invalid
	}
	result := Reply{ID: wire.ID, OK: *wire.OK, Value: bytes.Clone(wire.Value)}
	if present(wire.Error) {
		var fault struct {
			Code      string    `json:"code"`
			Message   *string   `json:"message"`
			Retryable *bool     `json:"retryable"`
			Identity  *Identity `json:"identity"`
		}
		if !allowedFields(wire.Error, "code", "message", "retryable", "identity") || strict(wire.Error, &fault) != nil || fault.Message == nil || len(*fault.Message) > 4096 || fault.Retryable == nil {
			return Reply{}, invalid
		}
		switch fault.Code {
		case "INVALID_ARGUMENT", "UNSUPPORTED_SCHEMA", "UNSUPPORTED_CAPABILITY", "DENIED", "NOT_FOUND", "CONFLICT",
			"LIMIT_EXCEEDED", "INVALID_STATE", "DESKTOP_CONTROLLED", "BUSY", "UNAVAILABLE", "DEADLINE_EXCEEDED", "UNCERTAIN", "INTERNAL":
		default:
			return Reply{}, invalid
		}
		if fault.Identity != nil {
			var fields map[string]json.RawMessage
			if json.Unmarshal(wire.Error, &fields) != nil || !exactDesktopFields(fields["identity"], "operation_ref", "idempotency_key") {
				return Reply{}, invalid
			}
		}
		if fault.Identity != nil && (fault.Code != "UNCERTAIN" || !identifier(fault.Identity.Operation) || !identifier(fault.Identity.Key)) {
			return Reply{}, invalid
		}
		result.Fault = &Fault{Code: fault.Code, Message: *fault.Message, Retryable: *fault.Retryable, Identity: fault.Identity}
	}
	if present(wire.Grants) {
		// The native Lua exporter spells an empty table as {}, including an empty
		// grants list. Only that exact empty object is equivalent to an empty list.
		empty := false
		if object(wire.Grants) {
			var members map[string]json.RawMessage
			if json.Unmarshal(wire.Grants, &members) == nil && len(members) == 0 {
				empty = true
			}
		}
		if !empty {
			var grants []json.RawMessage
			if json.Unmarshal(wire.Grants, &grants) != nil || len(grants) > 64 {
				return Reply{}, invalid
			}
			for _, grant := range grants {
				if !exactDesktopFields(grant, "grant_id", "issuer_owner_ref", "authorization_epoch", "expires_at") {
					return Reply{}, invalid
				}
			}
			if !strings.HasPrefix(strings.TrimSpace(string(wire.Grants)), "[") || strict(wire.Grants, &result.Grants) != nil || len(result.Grants) > 64 {
				return Reply{}, invalid
			}
		}
	}
	for _, grant := range result.Grants {
		if !identifier(grant.ID) || !identifier(grant.Owner.Node) || !identifier(grant.Owner.Service) ||
			(grant.Owner.Resource != "" && !identifier(grant.Owner.Resource)) || grant.Epoch < 1 || !canonicalTime(grant.Expires) {
			return Reply{}, invalid
		}
	}
	return result, nil
}

// Done closes when the caller-owned client actor lifetime ends. It is not
// transport connection evidence or a transferable authority.
func (r Reply) Done() <-chan struct{} { return r.lifetime }

func allowedFields(raw json.RawMessage, names ...string) bool {
	if !object(raw) {
		return false
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		return false
	}
	for field := range fields {
		found := false
		for _, name := range names {
			if field == name {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}
