// SPDX-License-Identifier: MIT

package display

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"

	ttyapi "github.com/wippyai/runtime/api/tty"
)

const (
	maxJSONDepth     = 8
	maxObjectMembers = 16
	maxArrayElements = MaxRows
)

type fieldKind int

const (
	kindString fieldKind = iota
	kindInt
	kindUint64
	kindBool
	kindStringArray
	kindObject
)

type fieldSpec struct {
	kind        fieldKind
	required    bool
	nullable    bool
	childSchema *objectSchema
}

type objectSchema struct {
	allowedFields map[string]fieldSpec
}

var (
	handshakeSchema = &objectSchema{
		allowedFields: map[string]fieldSpec{
			"type":    {kind: kindString, required: true},
			"version": {kind: kindString, required: true},
		},
	}

	cursorSchema = &objectSchema{
		allowedFields: map[string]fieldSpec{
			"column":  {kind: kindInt, required: true},
			"row":     {kind: kindInt, required: true},
			"visible": {kind: kindBool, required: true},
		},
	}

	snapshotSchema = &objectSchema{
		allowedFields: map[string]fieldSpec{
			"type":     {kind: kindString, required: true},
			"revision": {kind: kindUint64, required: true},
			"width":    {kind: kindInt, required: true},
			"height":   {kind: kindInt, required: true},
			"rows":     {kind: kindStringArray, required: true, nullable: true},
			"cursor":   {kind: kindObject, nullable: true, childSchema: cursorSchema},
		},
	}

	inputSchema = &objectSchema{
		allowedFields: map[string]fieldSpec{
			"type":  {kind: kindString, required: true},
			"seq":   {kind: kindUint64, required: true},
			"event": {kind: kindObject, required: true},
		},
	}

	resizeSchema = &objectSchema{
		allowedFields: map[string]fieldSpec{
			"type":   {kind: kindString, required: true},
			"seq":    {kind: kindUint64, required: true},
			"width":  {kind: kindInt, required: true},
			"height": {kind: kindInt, required: true},
		},
	}

	ackSchema = &objectSchema{
		allowedFields: map[string]fieldSpec{
			"type":  {kind: kindString, required: true},
			"seq":   {kind: kindUint64, required: true},
			"ok":    {kind: kindBool, required: true},
			"error": {kind: kindString},
		},
	}

	detachSchema = &objectSchema{
		allowedFields: map[string]fieldSpec{
			"type":   {kind: kindString, required: true},
			"reason": {kind: kindString},
		},
	}
)

// readPacket reads a 4-byte big-endian length prefix and then reads the exact
// payload bytes. Length is bounded BEFORE any buffer allocation. Payload bytes
// are verified to be valid UTF-8.
func readPacket(r io.Reader) ([]byte, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(lenBuf[:])
	if length > MaxPacketSize {
		return nil, fmt.Errorf("%w: length %d exceeds %d", ErrPacketTooLarge, length, MaxPacketSize)
	}
	if length < MinPacketSize {
		return nil, fmt.Errorf("%w: length %d smaller than %d", ErrPacketTooSmall, length, MinPacketSize)
	}

	buf := make([]byte, length)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	if !utf8.Valid(buf) {
		return nil, ErrInvalidUTF8
	}
	return buf, nil
}

// writePacket marshals and writes a message prefixed with its 4-byte big-endian length.
func writePacket(w io.Writer, msg any) error {
	packet, err := encodePacket(msg)
	if err != nil {
		return err
	}
	return writeEncodedPacket(w, packet)
}

func writeEncodedPacket(w io.Writer, packet []byte) error {
	n, err := w.Write(packet)
	if err == nil && n != len(packet) {
		return io.ErrShortWrite
	}
	return err
}

func encodePacket(msg any) ([]byte, error) {
	data, err := json.Marshal(msg)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidMessage, err)
	}
	if len(data) > MaxPacketSize {
		return nil, fmt.Errorf("%w: serialized size %d exceeds %d", ErrPacketTooLarge, len(data), MaxPacketSize)
	}
	if len(data) < MinPacketSize {
		return nil, fmt.Errorf("%w: serialized size %d smaller than %d", ErrPacketTooSmall, len(data), MinPacketSize)
	}

	pkt := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(pkt[:4], uint32(len(data)))
	copy(pkt[4:], data)
	return pkt, nil
}

// parseStrictJSON strictly decodes a single JSON object. It enforces maximum recursion
// depth (8), maximum object members (16), maximum array elements (MaxRows), rejects unknown,
// duplicate, or case-aliased keys, ensures valid UTF-8, and rejects trailing content without echoing.
func parseStrictJSON(data []byte) (map[string]any, error) {
	if !utf8.Valid(data) {
		return nil, ErrInvalidUTF8
	}
	r := bytes.NewReader(data)
	dec := json.NewDecoder(r)
	dec.UseNumber()

	tok, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("%w: invalid json start", ErrInvalidMessage)
	}
	if tok != json.Delim('{') {
		return nil, fmt.Errorf("%w: expected json object", ErrInvalidMessage)
	}

	result, err := parseObjectTokens(dec, 1)
	if err != nil {
		return nil, err
	}

	// Verify no trailing tokens exist without echoing raw content.
	for {
		_, err := dec.Token()
		if err == io.EOF {
			break
		}
		return nil, ErrTrailingContent
	}

	// Verify no trailing non-whitespace bytes exist in decoder buffer.
	buffered, _ := io.ReadAll(dec.Buffered())
	if len(bytes.TrimSpace(buffered)) > 0 {
		return nil, ErrTrailingContent
	}

	return result, nil
}

func parseObjectTokens(dec *json.Decoder, depth int) (map[string]any, error) {
	if depth > maxJSONDepth {
		return nil, fmt.Errorf("%w: json depth exceeds limit %d", ErrInvalidMessage, maxJSONDepth)
	}

	obj := make(map[string]any)
	seenLower := make(map[string]bool)
	count := 0

	for dec.More() {
		count++
		if count > maxObjectMembers {
			return nil, fmt.Errorf("%w: object member count exceeds limit %d", ErrInvalidMessage, maxObjectMembers)
		}

		kTok, err := dec.Token()
		if err != nil {
			return nil, fmt.Errorf("%w: invalid object key", ErrInvalidMessage)
		}
		k, ok := kTok.(string)
		if !ok {
			return nil, fmt.Errorf("%w: object key must be string", ErrInvalidMessage)
		}
		if !utf8.ValidString(k) {
			return nil, ErrInvalidUTF8
		}
		if len(k) > MaxStringLength {
			return nil, fmt.Errorf("%w: object key length exceeds limit", ErrInvalidMessage)
		}

		kLower := strings.ToLower(k)
		if seenLower[kLower] {
			return nil, fmt.Errorf("%w: duplicate key", ErrDuplicateField)
		}
		seenLower[kLower] = true

		val, err := parseValueToken(dec, depth)
		if err != nil {
			return nil, err
		}
		obj[k] = val
	}

	closeTok, err := dec.Token()
	if err != nil || closeTok != json.Delim('}') {
		return nil, fmt.Errorf("%w: expected '}'", ErrInvalidMessage)
	}

	return obj, nil
}

func parseValueToken(dec *json.Decoder, depth int) (any, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, fmt.Errorf("%w: invalid token", ErrInvalidMessage)
	}
	if tok == nil {
		return nil, nil // JSON null
	}

	switch v := tok.(type) {
	case string:
		if !utf8.ValidString(v) {
			return nil, ErrInvalidUTF8
		}
		return v, nil
	case bool:
		return v, nil
	case json.Number:
		return v, nil
	case json.Delim:
		switch v {
		case '{':
			return parseObjectTokens(dec, depth+1)
		case '[':
			return parseArrayTokens(dec, depth+1)
		default:
			return nil, fmt.Errorf("%w: unexpected delimiter", ErrInvalidMessage)
		}
	default:
		return nil, fmt.Errorf("%w: unexpected token", ErrInvalidMessage)
	}
}

func parseArrayTokens(dec *json.Decoder, depth int) ([]any, error) {
	if depth > maxJSONDepth {
		return nil, fmt.Errorf("%w: json depth exceeds limit %d", ErrInvalidMessage, maxJSONDepth)
	}

	var arr []any
	count := 0
	for dec.More() {
		count++
		if count > maxArrayElements {
			return nil, fmt.Errorf("%w: array element count exceeds limit %d", ErrInvalidSnapshot, maxArrayElements)
		}
		val, err := parseValueToken(dec, depth)
		if err != nil {
			return nil, err
		}
		arr = append(arr, val)
	}
	closeTok, err := dec.Token()
	if err != nil || closeTok != json.Delim(']') {
		return nil, fmt.Errorf("%w: expected ']'", ErrInvalidMessage)
	}
	return arr, nil
}

func validateAgainstSchema(raw map[string]any, s *objectSchema) error {
	for k, val := range raw {
		spec, ok := s.allowedFields[k]
		if !ok {
			dispKey := k
			if len(dispKey) > 32 {
				dispKey = dispKey[:32] + "..."
			}
			return fmt.Errorf("%w: %q", ErrUnknownField, dispKey)
		}
		if val == nil {
			if !spec.nullable {
				return fmt.Errorf("%w: field %q cannot be null", ErrNullField, k)
			}
			continue
		}

		switch spec.kind {
		case kindString:
			str, ok := val.(string)
			if !ok {
				return fmt.Errorf("%w: %q expected string, got %T", ErrInvalidMessage, k, val)
			}
			if len(str) > MaxStringLength {
				return fmt.Errorf("%w: %q string exceeds limit", ErrInvalidMessage, k)
			}
		case kindInt:
			num, ok := val.(json.Number)
			if !ok {
				return fmt.Errorf("%w: %q expected number, got %T", ErrInvalidMessage, k, val)
			}
			if _, err := num.Int64(); err != nil {
				return fmt.Errorf("%w: %q invalid integer", ErrInvalidMessage, k)
			}
		case kindUint64:
			num, ok := val.(json.Number)
			if !ok {
				return fmt.Errorf("%w: %q expected number, got %T", ErrInvalidMessage, k, val)
			}
			_, err := strconv.ParseUint(string(num), 10, 64)
			if err != nil {
				return fmt.Errorf("%w: %q invalid uint64", ErrInvalidMessage, k)
			}
		case kindBool:
			if _, ok := val.(bool); !ok {
				return fmt.Errorf("%w: %q expected bool, got %T", ErrInvalidMessage, k, val)
			}
		case kindStringArray:
			arr, ok := val.([]any)
			if !ok {
				return fmt.Errorf("%w: %q expected array, got %T", ErrInvalidMessage, k, val)
			}
			if len(arr) > MaxRows {
				return fmt.Errorf("%w: %q row count %d exceeds %d", ErrInvalidSnapshot, k, len(arr), MaxRows)
			}
			for i, elem := range arr {
				if elem == nil {
					return fmt.Errorf("%w: %q[%d] cannot be null", ErrNullField, k, i)
				}
				str, ok := elem.(string)
				if !ok {
					return fmt.Errorf("%w: %q[%d] expected string, got %T", ErrInvalidMessage, k, i, elem)
				}
				if len(str) > MaxRowLength {
					return fmt.Errorf("%w: %q[%d] length %d exceeds %d", ErrInvalidSnapshot, k, i, len(str), MaxRowLength)
				}
			}
		case kindObject:
			childObj, ok := val.(map[string]any)
			if !ok {
				return fmt.Errorf("%w: %q expected object, got %T", ErrInvalidMessage, k, val)
			}
			if spec.childSchema != nil {
				if err := validateAgainstSchema(childObj, spec.childSchema); err != nil {
					return err
				}
			}
		}
	}

	for k, spec := range s.allowedFields {
		if spec.required {
			if _, ok := raw[k]; !ok {
				return fmt.Errorf("%w: %q", ErrMissingField, k)
			}
		}
	}
	return nil
}

func decodeWireMessage(data []byte) (any, error) {
	raw, err := parseStrictJSON(data)
	if err != nil {
		return nil, err
	}
	if val, ok := raw["type"]; ok && val == nil {
		return nil, fmt.Errorf("%w: type field cannot be null", ErrNullField)
	}
	typeVal, ok := raw["type"].(string)
	if !ok || typeVal == "" {
		return nil, fmt.Errorf("%w: missing or invalid type field", ErrInvalidMessage)
	}

	switch typeVal {
	case "handshake":
		if err := validateAgainstSchema(raw, handshakeSchema); err != nil {
			return nil, err
		}
		return parseHandshake(raw)
	case "snapshot":
		if err := validateAgainstSchema(raw, snapshotSchema); err != nil {
			return nil, err
		}
		return parseSnapshot(raw)
	case "input":
		if err := validateAgainstSchema(raw, inputSchema); err != nil {
			return nil, err
		}
		return parseInput(raw)
	case "resize":
		if err := validateAgainstSchema(raw, resizeSchema); err != nil {
			return nil, err
		}
		return parseResize(raw)
	case "ack":
		if err := validateAgainstSchema(raw, ackSchema); err != nil {
			return nil, err
		}
		return parseAck(raw)
	case "detach":
		if err := validateAgainstSchema(raw, detachSchema); err != nil {
			return nil, err
		}
		return parseDetach(raw)
	default:
		return nil, fmt.Errorf("%w: unknown message type", ErrInvalidMessage)
	}
}

func parseHandshake(raw map[string]any) (*msgHandshake, error) {
	return &msgHandshake{
		Type:    raw["type"].(string),
		Version: raw["version"].(string),
	}, nil
}

func parseSnapshot(raw map[string]any) (*msgSnapshot, error) {
	revNum := raw["revision"].(json.Number)
	rev, _ := strconv.ParseUint(string(revNum), 10, 64)
	wNum := raw["width"].(json.Number)
	w, _ := wNum.Int64()
	hNum := raw["height"].(json.Number)
	h, _ := hNum.Int64()

	var rows []string
	if raw["rows"] != nil {
		rowsRaw := raw["rows"].([]any)
		rows = make([]string, len(rowsRaw))
		for i, r := range rowsRaw {
			rows[i] = r.(string)
		}
	} else {
		rows = []string{}
	}

	var cursor *wireCursor
	if raw["cursor"] != nil {
		cObj := raw["cursor"].(map[string]any)
		colNum := cObj["column"].(json.Number)
		col, _ := colNum.Int64()
		rowNum := cObj["row"].(json.Number)
		row, _ := rowNum.Int64()
		vis := cObj["visible"].(bool)
		cursor = &wireCursor{
			Column:  int(col),
			Row:     int(row),
			Visible: vis,
		}
	}

	snap := &msgSnapshot{
		Type:     "snapshot",
		Revision: uint64(rev),
		Width:    int(w),
		Height:   int(h),
		Rows:     rows,
		Cursor:   cursor,
	}
	return snap, nil
}

func parseWireEvent(raw map[string]any) (wireEvent, error) {
	if val, ok := raw["type"]; ok && val == nil {
		return wireEvent{}, fmt.Errorf("%w: event type cannot be null", ErrNullField)
	}
	typeVal, ok := raw["type"].(string)
	if !ok || typeVal == "" {
		return wireEvent{}, fmt.Errorf("%w: event missing type", ErrMissingField)
	}

	we := wireEvent{Type: typeVal}

	switch typeVal {
	case "key":
		for k := range raw {
			switch k {
			case "type", "key", "key_type", "action", "alt", "ctrl", "shift":
			default:
				dispKey := k
				if len(dispKey) > 32 {
					dispKey = dispKey[:32] + "..."
				}
				return wireEvent{}, fmt.Errorf("%w: field %q not allowed in key event", ErrUnknownField, dispKey)
			}
		}
		if val, ok := raw["key"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: key cannot be null", ErrNullField)
		}
		key, ok := raw["key"].(string)
		if !ok || key == "" {
			return wireEvent{}, fmt.Errorf("%w: key field missing or empty", ErrMissingField)
		}
		if len(key) > MaxStringLength {
			return wireEvent{}, fmt.Errorf("%w: key string length exceeds max bound", ErrInvalidEvent)
		}
		if val, ok := raw["key_type"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: key_type cannot be null", ErrNullField)
		}
		keyType, ok := raw["key_type"].(string)
		if !ok || keyType == "" {
			return wireEvent{}, fmt.Errorf("%w: key_type field missing or empty", ErrMissingField)
		}
		if len(keyType) > MaxStringLength {
			return wireEvent{}, fmt.Errorf("%w: key_type string length exceeds max bound", ErrInvalidEvent)
		}
		if val, ok := raw["action"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: action cannot be null", ErrNullField)
		}
		action, ok := raw["action"].(string)
		if !ok || (action != "press" && action != "release") {
			return wireEvent{}, fmt.Errorf("%w: action must be press or release", ErrInvalidEvent)
		}
		we.Key = key
		we.KeyType = keyType
		we.Action = action
		if v, ok := raw["alt"].(bool); ok {
			we.Alt = v
		}
		if v, ok := raw["ctrl"].(bool); ok {
			we.Ctrl = v
		}
		if v, ok := raw["shift"].(bool); ok {
			we.Shift = v
		}

	case "mouse":
		for k := range raw {
			switch k {
			case "type", "button", "action", "x", "y", "alt", "ctrl", "shift":
			default:
				dispKey := k
				if len(dispKey) > 32 {
					dispKey = dispKey[:32] + "..."
				}
				return wireEvent{}, fmt.Errorf("%w: field %q not allowed in mouse event", ErrUnknownField, dispKey)
			}
		}
		if val, ok := raw["button"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: button cannot be null", ErrNullField)
		}
		button, ok := raw["button"].(string)
		if !ok || button == "" {
			return wireEvent{}, fmt.Errorf("%w: mouse button missing", ErrMissingField)
		}
		if button != "left" && button != "middle" && button != "right" &&
			button != "wheel_up" && button != "wheel_down" && button != "none" {
			return wireEvent{}, fmt.Errorf("%w: invalid mouse button", ErrInvalidEvent)
		}
		if val, ok := raw["action"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: action cannot be null", ErrNullField)
		}
		action, ok := raw["action"].(string)
		if !ok || (action != "press" && action != "release" && action != "motion" && action != "wheel") {
			return wireEvent{}, fmt.Errorf("%w: invalid mouse action", ErrInvalidEvent)
		}
		if val, ok := raw["x"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: x cannot be null", ErrNullField)
		}
		xNum, ok := raw["x"].(json.Number)
		if !ok {
			return wireEvent{}, fmt.Errorf("%w: mouse x missing", ErrMissingField)
		}
		xInt, err := xNum.Int64()
		if err != nil || xInt < 1 || xInt > ttyapi.MaxViewportDimension {
			return wireEvent{}, fmt.Errorf("%w: mouse x must be >= 1", ErrInvalidEvent)
		}
		if val, ok := raw["y"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: y cannot be null", ErrNullField)
		}
		yNum, ok := raw["y"].(json.Number)
		if !ok {
			return wireEvent{}, fmt.Errorf("%w: mouse y missing", ErrMissingField)
		}
		yInt, err := yNum.Int64()
		if err != nil || yInt < 1 || yInt > ttyapi.MaxViewportDimension {
			return wireEvent{}, fmt.Errorf("%w: mouse y must be >= 1", ErrInvalidEvent)
		}
		x := int(xInt)
		y := int(yInt)
		we.Button = button
		we.Action = action
		we.X = &x
		we.Y = &y
		if v, ok := raw["alt"].(bool); ok {
			we.Alt = v
		}
		if v, ok := raw["ctrl"].(bool); ok {
			we.Ctrl = v
		}
		if v, ok := raw["shift"].(bool); ok {
			we.Shift = v
		}

	case "start", "resize":
		for k := range raw {
			switch k {
			case "type", "width", "height":
			default:
				dispKey := k
				if len(dispKey) > 32 {
					dispKey = dispKey[:32] + "..."
				}
				return wireEvent{}, fmt.Errorf("%w: field %q not allowed in %s event", ErrUnknownField, dispKey, typeVal)
			}
		}
		if val, ok := raw["width"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: width cannot be null", ErrNullField)
		}
		wNum, ok := raw["width"].(json.Number)
		if !ok {
			return wireEvent{}, fmt.Errorf("%w: width missing", ErrMissingField)
		}
		wInt, err := wNum.Int64()
		if err != nil || wInt < 1 {
			return wireEvent{}, fmt.Errorf("%w: invalid width", ErrInvalidEvent)
		}
		if val, ok := raw["height"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: height cannot be null", ErrNullField)
		}
		hNum, ok := raw["height"].(json.Number)
		if !ok {
			return wireEvent{}, fmt.Errorf("%w: height missing", ErrMissingField)
		}
		hInt, err := hNum.Int64()
		if err != nil || hInt < 1 {
			return wireEvent{}, fmt.Errorf("%w: invalid height", ErrInvalidEvent)
		}
		if err := ttyapi.ValidateViewportSize(int(wInt), int(hInt)); err != nil {
			return wireEvent{}, fmt.Errorf("%w: %w", ErrInvalidEvent, err)
		}
		w := int(wInt)
		h := int(hInt)
		we.Width = &w
		we.Height = &h

	case "paste":
		for k := range raw {
			switch k {
			case "type", "paste":
			default:
				dispKey := k
				if len(dispKey) > 32 {
					dispKey = dispKey[:32] + "..."
				}
				return wireEvent{}, fmt.Errorf("%w: field %q not allowed in paste event", ErrUnknownField, dispKey)
			}
		}
		if val, ok := raw["paste"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: paste cannot be null", ErrNullField)
		}
		paste, ok := raw["paste"].(string)
		if !ok {
			return wireEvent{}, fmt.Errorf("%w: paste field missing", ErrMissingField)
		}
		if len(paste) > MaxPasteLength {
			return wireEvent{}, fmt.Errorf("%w: paste content exceeds max bound", ErrInvalidEvent)
		}
		we.Paste = &paste

	case "focus":
		for k := range raw {
			switch k {
			case "type", "focused":
			default:
				dispKey := k
				if len(dispKey) > 32 {
					dispKey = dispKey[:32] + "..."
				}
				return wireEvent{}, fmt.Errorf("%w: field %q not allowed in focus event", ErrUnknownField, dispKey)
			}
		}
		if val, ok := raw["focused"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: focused cannot be null", ErrNullField)
		}
		focused, ok := raw["focused"].(bool)
		if !ok {
			return wireEvent{}, fmt.Errorf("%w: focus event requires explicit boolean 'focused'", ErrMissingField)
		}
		we.Focused = &focused

	case "visibility":
		for k := range raw {
			switch k {
			case "type", "visible":
			default:
				dispKey := k
				if len(dispKey) > 32 {
					dispKey = dispKey[:32] + "..."
				}
				return wireEvent{}, fmt.Errorf("%w: field %q not allowed in visibility event", ErrUnknownField, dispKey)
			}
		}
		if val, ok := raw["visible"]; ok && val == nil {
			return wireEvent{}, fmt.Errorf("%w: visible cannot be null", ErrNullField)
		}
		visible, ok := raw["visible"].(bool)
		if !ok {
			return wireEvent{}, fmt.Errorf("%w: visibility event requires explicit boolean 'visible'", ErrMissingField)
		}
		we.Visible = &visible

	case "close":
		for k := range raw {
			switch k {
			case "type":
			default:
				dispKey := k
				if len(dispKey) > 32 {
					dispKey = dispKey[:32] + "..."
				}
				return wireEvent{}, fmt.Errorf("%w: field %q not allowed in close event", ErrUnknownField, dispKey)
			}
		}

	default:
		return wireEvent{}, fmt.Errorf("%w: unrecognized event type", ErrInvalidEvent)
	}

	return we, nil
}

func parseInput(raw map[string]any) (*msgInput, error) {
	seqNum := raw["seq"].(json.Number)
	seq, err := strconv.ParseUint(string(seqNum), 10, 64)
	if err != nil || seq <= 0 {
		return nil, fmt.Errorf("%w: invalid seq", ErrInvalidMessage)
	}

	evObj, ok := raw["event"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%w: event must be object", ErrInvalidMessage)
	}

	we, err := parseWireEvent(evObj)
	if err != nil {
		return nil, err
	}

	return &msgInput{
		Type:  "input",
		Seq:   uint64(seq),
		Event: we,
	}, nil
}

func parseResize(raw map[string]any) (*msgResize, error) {
	seqNum := raw["seq"].(json.Number)
	seq, _ := strconv.ParseUint(string(seqNum), 10, 64)
	wNum := raw["width"].(json.Number)
	w, _ := wNum.Int64()
	hNum := raw["height"].(json.Number)
	h, _ := hNum.Int64()

	return &msgResize{
		Type:   "resize",
		Seq:    uint64(seq),
		Width:  int(w),
		Height: int(h),
	}, nil
}

func parseAck(raw map[string]any) (*msgAck, error) {
	seqNum := raw["seq"].(json.Number)
	seq, _ := strconv.ParseUint(string(seqNum), 10, 64)
	ok := raw["ok"].(bool)
	errMsg := ""
	if v, ok := raw["error"].(string); ok {
		errMsg = v
	}
	return &msgAck{
		Type:  "ack",
		Seq:   uint64(seq),
		Ok:    ok,
		Error: errMsg,
	}, nil
}

func parseDetach(raw map[string]any) (*msgDetach, error) {
	reason := ""
	if v, ok := raw["reason"].(string); ok {
		reason = v
	}
	return &msgDetach{
		Type:   "detach",
		Reason: reason,
	}, nil
}
