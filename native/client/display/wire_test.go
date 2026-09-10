// SPDX-License-Identifier: MIT

package display

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	ttyapi "github.com/wippyai/runtime/api/tty"
)

func makePacket(payload []byte) []byte {
	var buf bytes.Buffer
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(payload)))
	buf.Write(lenBuf[:])
	buf.Write(payload)
	return buf.Bytes()
}

func TestWirePacketBoundsBeforeAllocation(t *testing.T) {
	// Oversize length prefix
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], MaxPacketSize+1)
	r := bytes.NewReader(lenBuf[:])
	_, err := readPacket(r)
	if !errors.Is(err, ErrPacketTooLarge) {
		t.Fatalf("expected ErrPacketTooLarge, got %v", err)
	}

	// Undersize length prefix
	binary.BigEndian.PutUint32(lenBuf[:], MinPacketSize-1)
	r = bytes.NewReader(lenBuf[:])
	_, err = readPacket(r)
	if !errors.Is(err, ErrPacketTooSmall) {
		t.Fatalf("expected ErrPacketTooSmall, got %v", err)
	}

	// Normal packet
	pkt := makePacket([]byte(`{"type":"handshake","version":"bee.display.v1"}`))
	payload, err := readPacket(bytes.NewReader(pkt))
	if err != nil {
		t.Fatalf("unexpected readPacket err: %v", err)
	}
	if string(payload) != `{"type":"handshake","version":"bee.display.v1"}` {
		t.Fatalf("unexpected payload: %s", string(payload))
	}
}

func TestWireInvalidUTF8(t *testing.T) {
	// Invalid UTF-8 in packet framing
	raw := []byte{0xff, 0xfe, '{', '}'}
	pkt := makePacket(raw)
	_, err := readPacket(bytes.NewReader(pkt))
	if !errors.Is(err, ErrInvalidUTF8) {
		t.Fatalf("expected ErrInvalidUTF8 from readPacket, got %v", err)
	}

	// Invalid UTF-8 in decodeWireMessage
	_, err = decodeWireMessage(raw)
	if !errors.Is(err, ErrInvalidUTF8) {
		t.Fatalf("expected ErrInvalidUTF8 from decodeWireMessage, got %v", err)
	}
}

func TestWireTrailingContent(t *testing.T) {
	// Trailing non-whitespace string
	data := []byte(`{"type":"handshake","version":"bee.display.v1"} trailing`)
	_, err := decodeWireMessage(data)
	if !errors.Is(err, ErrTrailingContent) {
		t.Fatalf("expected ErrTrailingContent, got %v", err)
	}

	// Trailing second JSON object
	data = []byte(`{"type":"handshake","version":"bee.display.v1"}{"extra":1}`)
	_, err = decodeWireMessage(data)
	if !errors.Is(err, ErrTrailingContent) {
		t.Fatalf("expected ErrTrailingContent, got %v", err)
	}

	// Trailing whitespace is allowed
	data = []byte("{\"type\":\"handshake\",\"version\":\"bee.display.v1\"}\n  \t")
	msg, err := decodeWireMessage(data)
	if err != nil {
		t.Fatalf("unexpected err for trailing whitespace: %v", err)
	}
	hs, ok := msg.(*msgHandshake)
	if !ok || hs.Version != ProtocolVersion {
		t.Fatalf("unexpected msg: %v", msg)
	}
}

func TestWireUnknownAndDuplicateFields(t *testing.T) {
	tests := []struct {
		name        string
		json        string
		expectedErr error
	}{
		{
			name:        "unknown top-level field",
			json:        `{"type":"handshake","version":"bee.display.v1","extra":"value"}`,
			expectedErr: ErrUnknownField,
		},
		{
			name:        "unknown field in nested event",
			json:        `{"type":"input","seq":1,"event":{"type":"key","key":"a","key_type":"runes","action":"press","unknown":123}}`,
			expectedErr: ErrUnknownField,
		},
		{
			name:        "unknown field in nested cursor",
			json:        `{"type":"snapshot","revision":1,"width":80,"height":24,"rows":[],"cursor":{"column":0,"row":0,"visible":true,"bogus":1}}`,
			expectedErr: ErrUnknownField,
		},
		{
			name:        "exact duplicate field",
			json:        `{"type":"handshake","type":"handshake","version":"bee.display.v1"}`,
			expectedErr: ErrDuplicateField,
		},
		{
			name:        "case-aliased field",
			json:        `{"type":"handshake","Type":"handshake","version":"bee.display.v1"}`,
			expectedErr: ErrDuplicateField,
		},
		{
			name:        "case-mismatched field",
			json:        `{"type":"handshake","Version":"bee.display.v1"}`,
			expectedErr: ErrUnknownField,
		},
		{
			name:        "case-aliased nested field",
			json:        `{"type":"input","seq":1,"event":{"type":"key","key":"a","Key":"a","key_type":"runes","action":"press"}}`,
			expectedErr: ErrDuplicateField,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := decodeWireMessage([]byte(tc.json))
			if !errors.Is(err, tc.expectedErr) {
				t.Fatalf("expected %v, got %v", tc.expectedErr, err)
			}
		})
	}
}

func TestWireNullRequiredFields(t *testing.T) {
	tests := []struct {
		name string
		json string
	}{
		{
			name: "null type",
			json: `{"type":null,"version":"bee.display.v1"}`,
		},
		{
			name: "null version",
			json: `{"type":"handshake","version":null}`,
		},
		{
			name: "null seq",
			json: `{"type":"input","seq":null,"event":{"type":"key","key":"a","key_type":"runes","action":"press"}}`,
		},
		{
			name: "null event",
			json: `{"type":"input","seq":1,"event":null}`,
		},
		{
			name: "null width in resize",
			json: `{"type":"resize","seq":1,"width":null,"height":24}`,
		},
		{
			name: "null row in rows array",
			json: `{"type":"snapshot","revision":1,"width":80,"height":24,"rows":["ok",null]}`,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := decodeWireMessage([]byte(tc.json))
			if !errors.Is(err, ErrNullField) {
				t.Fatalf("expected ErrNullField, got %v", err)
			}
		})
	}
}

func TestWireNullableCursorInSnapshot(t *testing.T) {
	// Explicit null cursor is permitted (producer hasn't set explicit cursor yet)
	jsonNullCursor := `{"type":"snapshot","revision":1,"width":80,"height":24,"rows":["line1"],"cursor":null}`
	msg, err := decodeWireMessage([]byte(jsonNullCursor))
	if err != nil {
		t.Fatalf("unexpected error with null cursor: %v", err)
	}
	snap := msg.(*msgSnapshot)
	if snap.Cursor != nil {
		t.Fatalf("expected nil cursor, got %+v", snap.Cursor)
	}

	// Valid cursor
	jsonValidCursor := `{"type":"snapshot","revision":1,"width":80,"height":24,"rows":["line1"],"cursor":{"column":5,"row":2,"visible":true}}`
	msg, err = decodeWireMessage([]byte(jsonValidCursor))
	if err != nil {
		t.Fatalf("unexpected error with valid cursor: %v", err)
	}
	snap = msg.(*msgSnapshot)
	if snap.Cursor == nil || snap.Cursor.Column != 5 || snap.Cursor.Row != 2 || !snap.Cursor.Visible {
		t.Fatalf("unexpected cursor: %+v", snap.Cursor)
	}
}

func TestEventValidation(t *testing.T) {
	// Valid events
	validEvents := []ttyapi.Event{
		{Type: "key", Key: "a", KeyType: "runes", Action: "press"},
		{Type: "key", Key: "enter", KeyType: "enter", Action: "release"},
		{Type: "mouse", Action: "press", Button: "left", X: 10, Y: 5},
		{Type: "start", Width: 80, Height: 24},
		{Type: "resize", Width: 80, Height: 24},
		{Type: "paste", Paste: "hello world"},
		{Type: "focus", Focused: true},
		{Type: "focus", Focused: false},
		{Type: "visibility", Visible: true},
		{Type: "visibility", Visible: false},
		{Type: "close"},
	}
	for _, ev := range validEvents {
		if err := validateEvent(ev); err != nil {
			t.Fatalf("expected valid event %+v, got %v", ev, err)
		}
	}

	// Invalid event type
	if err := validateEvent(ttyapi.Event{Type: "unknown"}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for unknown event type, got %v", err)
	}

	// Missing key action
	if err := validateEvent(ttyapi.Event{Type: "key", Key: "a", KeyType: "runes"}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for missing action, got %v", err)
	}

	// Invalid key action
	if err := validateEvent(ttyapi.Event{Type: "key", Key: "a", KeyType: "runes", Action: "bad_action"}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for bad action, got %v", err)
	}

	// Key event with contradictory oversized paste (must not be silently ignored)
	if err := validateEvent(ttyapi.Event{Type: "key", Key: "a", KeyType: "runes", Action: "press", Paste: "something"}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for key event with paste field, got %v", err)
	}

	// Key event with contradictory mouse coordinates
	if err := validateEvent(ttyapi.Event{Type: "key", Key: "a", KeyType: "runes", Action: "press", X: 1, Y: 1}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for key event with mouse coordinates, got %v", err)
	}

	// Invalid mouse button
	if err := validateEvent(ttyapi.Event{Type: "mouse", Action: "press", Button: "bad_button", X: 1, Y: 1}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for bad button, got %v", err)
	}

	// Mouse coordinates out of bounds (< 1)
	if err := validateEvent(ttyapi.Event{Type: "mouse", Action: "press", Button: "left", X: 0, Y: 5}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for 0 X, got %v", err)
	}

	// Resize invalid width (0)
	if err := validateEvent(ttyapi.Event{Type: "resize", Width: 0, Height: 24}); !errors.Is(err, ErrInvalidEvent) {
		t.Fatalf("expected ErrInvalidEvent for 0 width, got %v", err)
	}
}

func TestSnapshotValidation(t *testing.T) {
	// Valid snapshot
	validSnap := ttyapi.Snapshot{
		Revision: 1,
		Width:    80,
		Height:   24,
		Rows:     []string{"hello", "world"},
		Cursor:   &ttyapi.Cursor{Column: 0, Row: 0, Visible: true},
	}
	if err := validateSnapshot(validSnap); err != nil {
		t.Fatalf("expected valid snapshot, got %v", err)
	}

	// Valid empty rows snapshot
	emptyRowsSnap := ttyapi.Snapshot{
		Revision: 1,
		Width:    80,
		Height:   24,
		Rows:     []string{},
	}
	if err := validateSnapshot(emptyRowsSnap); err != nil {
		t.Fatalf("expected valid empty rows snapshot, got %v", err)
	}

	// Zero geometry snapshot
	zeroSnap := ttyapi.Snapshot{
		Revision: 1,
		Width:    0,
		Height:   0,
	}
	if err := validateSnapshot(zeroSnap); !errors.Is(err, ErrInvalidSnapshot) {
		t.Fatalf("expected ErrInvalidSnapshot for zero geometry, got %v", err)
	}

	// Exceeding viewport cells limit
	badCells := ttyapi.Snapshot{
		Width:  65535,
		Height: 65535,
	}
	if err := validateSnapshot(badCells); !errors.Is(err, ErrInvalidSnapshot) {
		t.Fatalf("expected ErrInvalidSnapshot for huge cell count, got %v", err)
	}

	// Exceeding row length
	badRow := ttyapi.Snapshot{
		Width:  80,
		Height: 24,
		Rows:   []string{strings.Repeat("a", MaxRowLength+1)},
	}
	if err := validateSnapshot(badRow); !errors.Is(err, ErrInvalidSnapshot) {
		t.Fatalf("expected ErrInvalidSnapshot for row exceeding MaxRowLength, got %v", err)
	}
}

func TestBoundedMalformedNesting(t *testing.T) {
	// 9 levels of nested objects (exceeds limit 8)
	nestedObj := `{"type":"handshake","version":"bee.display.v1","a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":1}}}}}}}}}`
	_, err := decodeWireMessage([]byte(nestedObj))
	if err == nil {
		t.Fatal("expected error for nesting depth > 8, got nil")
	}

	// More than 16 object members
	manyFields := `{"type":"handshake","version":"bee.display.v1","f1":1,"f2":2,"f3":3,"f4":4,"f5":5,"f6":6,"f7":7,"f8":8,"f9":9,"f10":10,"f11":11,"f12":12,"f13":13,"f14":14,"f15":15}`
	_, err = decodeWireMessage([]byte(manyFields))
	if err == nil {
		t.Fatal("expected error for > 16 object members, got nil")
	}
}

func TestWireFocusAndVisibilityExplicitBooleans(t *testing.T) {
	// Focus event with false should serialize focused: false explicitly
	evFocus := ttyapi.Event{Type: "focus", Focused: false}
	weFocus := toWireEvent(evFocus)
	data, err := json.Marshal(weFocus)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}
	if !strings.Contains(string(data), `"focused":false`) {
		t.Fatalf("expected '\"focused\":false' in wire json, got %s", string(data))
	}

	// Visibility event with false should serialize visible: false explicitly
	evVis := ttyapi.Event{Type: "visibility", Visible: false}
	weVis := toWireEvent(evVis)
	data, err = json.Marshal(weVis)
	if err != nil {
		t.Fatalf("Marshal failed: %v", err)
	}
	if !strings.Contains(string(data), `"visible":false`) {
		t.Fatalf("expected '\"visible\":false' in wire json, got %s", string(data))
	}

	// Decoding focus event without 'focused' boolean must be rejected
	missingFocusJSON := `{"type":"input","seq":1,"event":{"type":"focus"}}`
	_, err = decodeWireMessage([]byte(missingFocusJSON))
	if !errors.Is(err, ErrMissingField) {
		t.Fatalf("expected ErrMissingField for focus missing boolean, got: %v", err)
	}

	// Decoding visibility event without 'visible' boolean must be rejected
	missingVisJSON := `{"type":"input","seq":1,"event":{"type":"visibility"}}`
	_, err = decodeWireMessage([]byte(missingVisJSON))
	if !errors.Is(err, ErrMissingField) {
		t.Fatalf("expected ErrMissingField for visibility missing boolean, got: %v", err)
	}
}
