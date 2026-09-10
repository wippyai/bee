//go:build meshclient

// SPDX-License-Identifier: MIT
package mesh

import (
	"bytes"
	"encoding/json"
	"unicode/utf8"

	"github.com/wippyai/runtime/api/payload"
)

// controlBody accepts the runtime's two record representations: explicit JSON
// and Go values normalized from Lua by the native message codec. Native handles,
// custom marshalers and binary values are not application control records.
func controlBody(item payload.Payload) ([]byte, bool) {
	if item == nil {
		return nil, false
	}
	switch item.Format() {
	case payload.JSON:
		body, ok := item.Data().([]byte)
		trimmed := bytes.TrimSpace(body)
		return body, ok && len(body) <= maxMessageBytes && len(trimmed) > 0 && trimmed[0] == '{' && json.Valid(body)
	case payload.Golang:
		record, ok := item.Data().(map[string]any)
		if !ok || record == nil {
			return nil, false
		}
		budget := maxMessageBytes
		if !boundedRecord(item.Data(), 0, &budget) {
			return nil, false
		}
		body, err := json.Marshal(item.Data())
		return body, err == nil && len(body) <= maxMessageBytes
	default:
		return nil, false
	}
}

// Bound input traversal before encoding. The raw value budget bounds temporary
// JSON expansion; the final encoded-byte limit remains authoritative. Depth also
// rejects cycles injected by trusted local native code without following them.
func boundedRecord(value any, depth int, budget *int) bool {
	if depth > 32 || *budget <= 0 {
		return false
	}
	*budget -= 1
	switch value := value.(type) {
	case nil, bool:
	case string:
		*budget -= len(value)
		if !utf8.ValidString(value) {
			return false
		}
	case float64, float32, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		*budget -= 8
	case []any:
		if len(value) > *budget {
			return false
		}
		for _, member := range value {
			if !boundedRecord(member, depth+1, budget) {
				return false
			}
		}
	case map[string]any:
		if len(value) > *budget {
			return false
		}
		for key, member := range value {
			*budget -= len(key) + 1
			if !utf8.ValidString(key) || !boundedRecord(member, depth+1, budget) {
				return false
			}
		}
	default:
		return false
	}
	return *budget >= 0
}
