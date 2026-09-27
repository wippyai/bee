// SPDX-License-Identifier: MIT

package jsonwire

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type nested struct {
	Value string `json:"value"`
}

type document struct {
	ID     string          `json:"id"`
	Detail nested          `json:"detail"`
	Label  string          `json:"label,omitempty"`
	Data   json.RawMessage `json:"data,omitempty"`
}

func TestDecodeObjectPreservesItsConcreteType(t *testing.T) {
	got, err := DecodeObject[document]([]byte(`{"id":"item","detail":{"value":"ready"}}`), 256, "id", "detail")
	if err != nil || got.ID != "item" || got.Detail.Value != "ready" || got.Label != "" {
		t.Fatalf("decoded object = %+v, %v", got, err)
	}
}

func TestValidateAcceptsOneValueAndRejectsDuplicateMembers(t *testing.T) {
	for _, raw := range []string{`null`, `7`, `[]`, `{"items":[{"id":"one"}]}`} {
		if err := Validate([]byte(raw), 256); err != nil {
			t.Errorf("rejected valid JSON %q: %v", raw, err)
		}
	}
	for _, raw := range []string{
		`{"id":"one","id":"two"}`,
		`{"item":{"id":"one","id":"two"}}`,
		`[] {}`,
	} {
		if err := Validate([]byte(raw), 256); !errors.Is(err, ErrInvalidObject) {
			t.Errorf("accepted ambiguous JSON %q: %v", raw, err)
		}
	}
}

func TestDecodeObjectRejectsAmbiguousOrIncompleteDocuments(t *testing.T) {
	for _, raw := range []string{
		`{"id":"one","id":"two","detail":{"value":"ready"}}`,
		`{"id":"one","detail":{"value":"ready","value":"other"}}`,
		`{"ID":"one","detail":{"value":"ready"}}`,
		`{"id":"one","detail":{"value":"ready"},"extra":true}`,
		`{"id":"one","detail":{"value":"ready"}} {}`,
		`{"id":null,"detail":{"value":"ready"}}`,
		`[]`,
	} {
		t.Run(raw, func(t *testing.T) {
			if _, err := DecodeObject[document]([]byte(raw), 256, "id", "detail"); !errors.Is(err, ErrInvalidObject) {
				t.Fatalf("accepted invalid object: %v", err)
			}
		})
	}
}

func TestDecodeObjectRejectsOversizedAndOverdeepDocuments(t *testing.T) {
	if _, err := DecodeObject[document]([]byte(`{"id":"item","detail":{"value":"ready"}}`), 8, "id"); !errors.Is(err, ErrInvalidObject) {
		t.Fatalf("accepted oversized object: %v", err)
	}
	deep := `{"id":"item","detail":{"value":"ready"},"data":` + strings.Repeat("[", maxDepth+1) + `0` + strings.Repeat("]", maxDepth+1) + `}`
	if _, err := DecodeObject[document]([]byte(deep), len(deep), "id", "detail"); !errors.Is(err, ErrInvalidObject) {
		t.Fatalf("accepted overdeep object: %v", err)
	}
}
