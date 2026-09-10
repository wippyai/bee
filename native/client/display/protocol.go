// SPDX-License-Identifier: MIT

package display

import (
	"fmt"
	"unicode/utf8"

	ttyapi "github.com/wippyai/runtime/api/tty"
)

const (
	// ProtocolVersion is the exact wire protocol handshake version.
	ProtocolVersion = "bee.display.v1"

	// MaxPacketSize bounds the maximum wire packet size before allocation (2 MiB).
	MaxPacketSize = 2 * 1024 * 1024

	// MinPacketSize is the smallest valid JSON message size (2 bytes for {}).
	MinPacketSize = 2

	// MaxRowLength bounds row length in a snapshot (64 KiB).
	MaxRowLength = 65536

	// MaxRows bounds total rows in a snapshot.
	MaxRows = ttyapi.MaxViewportDimension // 65535

	// MaxStringLength bounds short protocol strings (keys, types, actions, error reasons).
	MaxStringLength = 1024

	// MaxPasteLength bounds paste event strings (1 MiB).
	MaxPasteLength = 1024 * 1024
)

// Wire cursor payload.
type wireCursor struct {
	Column  int  `json:"column"`
	Row     int  `json:"row"`
	Visible bool `json:"visible"`
}

func toWireCursor(c *ttyapi.Cursor) *wireCursor {
	if c == nil {
		return nil
	}
	return &wireCursor{
		Column:  c.Column,
		Row:     c.Row,
		Visible: c.Visible,
	}
}

func fromWireCursor(wc *wireCursor) *ttyapi.Cursor {
	if wc == nil {
		return nil
	}
	return &ttyapi.Cursor{
		Column:  wc.Column,
		Row:     wc.Row,
		Visible: wc.Visible,
	}
}

// Wire event payload matching native tty.Event and Bee core decoder.
type wireEvent struct {
	Type    string  `json:"type"`
	Key     string  `json:"key,omitempty"`
	KeyType string  `json:"key_type,omitempty"`
	Action  string  `json:"action,omitempty"`
	Button  string  `json:"button,omitempty"`
	Paste   *string `json:"paste,omitempty"`
	X       *int    `json:"x,omitempty"`
	Y       *int    `json:"y,omitempty"`
	Width   *int    `json:"width,omitempty"`
	Height  *int    `json:"height,omitempty"`
	Alt     bool    `json:"alt,omitempty"`
	Ctrl    bool    `json:"ctrl,omitempty"`
	Shift   bool    `json:"shift,omitempty"`
	Focused *bool   `json:"focused,omitempty"`
	Visible *bool   `json:"visible,omitempty"`
}

func toWireEvent(ev ttyapi.Event) wireEvent {
	we := wireEvent{
		Type: ev.Type,
	}
	switch ev.Type {
	case "key":
		we.Key = ev.Key
		we.KeyType = ev.KeyType
		we.Action = ev.Action
		we.Alt = ev.Alt
		we.Ctrl = ev.Ctrl
		we.Shift = ev.Shift
	case "mouse":
		we.Button = ev.Button
		we.Action = ev.Action
		x := ev.X
		y := ev.Y
		we.X = &x
		we.Y = &y
		we.Alt = ev.Alt
		we.Ctrl = ev.Ctrl
		we.Shift = ev.Shift
	case "start", "resize":
		w := ev.Width
		h := ev.Height
		we.Width = &w
		we.Height = &h
	case "paste":
		paste := ev.Paste
		we.Paste = &paste
	case "focus":
		focused := ev.Focused
		we.Focused = &focused
	case "visibility":
		visible := ev.Visible
		we.Visible = &visible
	case "close":
		// No extra payload
	}
	return we
}

func fromWireEvent(we wireEvent) ttyapi.Event {
	ev := ttyapi.Event{
		Type: we.Type,
	}
	switch we.Type {
	case "key":
		ev.Key = we.Key
		ev.KeyType = we.KeyType
		ev.Action = we.Action
		ev.Alt = we.Alt
		ev.Ctrl = we.Ctrl
		ev.Shift = we.Shift
	case "mouse":
		ev.Button = we.Button
		ev.Action = we.Action
		if we.X != nil {
			ev.X = *we.X
		}
		if we.Y != nil {
			ev.Y = *we.Y
		}
		ev.Alt = we.Alt
		ev.Ctrl = we.Ctrl
		ev.Shift = we.Shift
	case "start", "resize":
		if we.Width != nil {
			ev.Width = *we.Width
		}
		if we.Height != nil {
			ev.Height = *we.Height
		}
	case "paste":
		if we.Paste != nil {
			ev.Paste = *we.Paste
		}
	case "focus":
		if we.Focused != nil {
			ev.Focused = *we.Focused
		}
	case "visibility":
		if we.Visible != nil {
			ev.Visible = *we.Visible
		}
	case "close":
		// No extra payload
	}
	return ev
}

// Concrete wire messages.
type msgHandshake struct {
	Type    string `json:"type"`
	Version string `json:"version"`
}

type msgSnapshot struct {
	Type     string      `json:"type"`
	Revision uint64      `json:"revision"`
	Width    int         `json:"width"`
	Height   int         `json:"height"`
	Rows     []string    `json:"rows"`
	Cursor   *wireCursor `json:"cursor"`
}

type msgInput struct {
	Type  string    `json:"type"`
	Seq   uint64    `json:"seq"`
	Event wireEvent `json:"event"`
}

type msgResize struct {
	Type   string `json:"type"`
	Seq    uint64 `json:"seq"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

type msgAck struct {
	Type  string `json:"type"`
	Seq   uint64 `json:"seq"`
	Ok    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type msgDetach struct {
	Type   string `json:"type"`
	Reason string `json:"reason,omitempty"`
}

// Validation helpers.

func validateEvent(ev ttyapi.Event) error {
	if !utf8.ValidString(ev.Type) || !utf8.ValidString(ev.Key) || !utf8.ValidString(ev.KeyType) ||
		!utf8.ValidString(ev.Action) || !utf8.ValidString(ev.Button) || !utf8.ValidString(ev.Paste) {
		return fmt.Errorf("%w: event contains invalid utf-8 string", ErrInvalidEvent)
	}

	switch ev.Type {
	case "key":
		if ev.Button != "" || ev.Paste != "" || ev.X != 0 || ev.Y != 0 ||
			ev.Width != 0 || ev.Height != 0 || ev.Focused || ev.Visible {
			return fmt.Errorf("%w: key event contains contradictory fields", ErrInvalidEvent)
		}
		if ev.Key == "" || len(ev.Key) > MaxStringLength {
			return fmt.Errorf("%w: key missing or exceeds max bound", ErrInvalidEvent)
		}
		if ev.KeyType == "" || len(ev.KeyType) > MaxStringLength {
			return fmt.Errorf("%w: key_type missing or exceeds max bound", ErrInvalidEvent)
		}
		if ev.Action != "press" && ev.Action != "release" {
			return fmt.Errorf("%w: invalid key action (must be press or release)", ErrInvalidEvent)
		}

	case "mouse":
		if ev.Key != "" || ev.KeyType != "" || ev.Paste != "" ||
			ev.Width != 0 || ev.Height != 0 || ev.Focused || ev.Visible {
			return fmt.Errorf("%w: mouse event contains contradictory fields", ErrInvalidEvent)
		}
		if ev.Action != "press" && ev.Action != "release" && ev.Action != "motion" && ev.Action != "wheel" {
			return fmt.Errorf("%w: invalid mouse action", ErrInvalidEvent)
		}
		if ev.Button != "left" && ev.Button != "middle" && ev.Button != "right" &&
			ev.Button != "wheel_up" && ev.Button != "wheel_down" && ev.Button != "none" {
			return fmt.Errorf("%w: invalid mouse button", ErrInvalidEvent)
		}
		if ev.X < 1 || ev.X > ttyapi.MaxViewportDimension || ev.Y < 1 || ev.Y > ttyapi.MaxViewportDimension {
			return fmt.Errorf("%w: mouse coordinates out of bounds (%d, %d), must be >= 1", ErrInvalidEvent, ev.X, ev.Y)
		}

	case "start", "resize":
		if ev.Key != "" || ev.KeyType != "" || ev.Action != "" || ev.Button != "" || ev.Paste != "" ||
			ev.X != 0 || ev.Y != 0 || ev.Alt || ev.Ctrl || ev.Shift || ev.Focused || ev.Visible {
			return fmt.Errorf("%w: %s event contains contradictory fields", ErrInvalidEvent, ev.Type)
		}
		if err := ttyapi.ValidateViewportSize(ev.Width, ev.Height); err != nil {
			return fmt.Errorf("%w: invalid %s geometry: %w", ErrInvalidEvent, ev.Type, err)
		}

	case "paste":
		if ev.Key != "" || ev.KeyType != "" || ev.Action != "" || ev.Button != "" ||
			ev.X != 0 || ev.Y != 0 || ev.Width != 0 || ev.Height != 0 ||
			ev.Alt || ev.Ctrl || ev.Shift || ev.Focused || ev.Visible {
			return fmt.Errorf("%w: paste event contains contradictory fields", ErrInvalidEvent)
		}
		if len(ev.Paste) > MaxPasteLength {
			return fmt.Errorf("%w: paste content exceeds max bound %d", ErrInvalidEvent, MaxPasteLength)
		}

	case "focus":
		if ev.Key != "" || ev.KeyType != "" || ev.Action != "" || ev.Button != "" || ev.Paste != "" ||
			ev.X != 0 || ev.Y != 0 || ev.Width != 0 || ev.Height != 0 ||
			ev.Alt || ev.Ctrl || ev.Shift || ev.Visible {
			return fmt.Errorf("%w: focus event contains contradictory fields", ErrInvalidEvent)
		}

	case "visibility":
		if ev.Key != "" || ev.KeyType != "" || ev.Action != "" || ev.Button != "" || ev.Paste != "" ||
			ev.X != 0 || ev.Y != 0 || ev.Width != 0 || ev.Height != 0 ||
			ev.Alt || ev.Ctrl || ev.Shift || ev.Focused {
			return fmt.Errorf("%w: visibility event contains contradictory fields", ErrInvalidEvent)
		}

	case "close":
		if ev.Key != "" || ev.KeyType != "" || ev.Action != "" || ev.Button != "" || ev.Paste != "" ||
			ev.X != 0 || ev.Y != 0 || ev.Width != 0 || ev.Height != 0 ||
			ev.Alt || ev.Ctrl || ev.Shift || ev.Focused || ev.Visible {
			return fmt.Errorf("%w: close event contains contradictory fields", ErrInvalidEvent)
		}

	default:
		return fmt.Errorf("%w: unrecognized event type", ErrInvalidEvent)
	}
	return nil
}

func validateSnapshot(s ttyapi.Snapshot) error {
	if err := ttyapi.ValidateViewportSize(s.Width, s.Height); err != nil {
		return fmt.Errorf("%w: invalid snapshot geometry (%d, %d): %w", ErrInvalidSnapshot, s.Width, s.Height, err)
	}
	if len(s.Rows) > MaxRows {
		return fmt.Errorf("%w: row count %d exceeds max %d", ErrInvalidSnapshot, len(s.Rows), MaxRows)
	}
	for i, r := range s.Rows {
		if len(r) > MaxRowLength {
			return fmt.Errorf("%w: row %d length %d exceeds max %d", ErrInvalidSnapshot, i, len(r), MaxRowLength)
		}
		if !utf8.ValidString(r) {
			return fmt.Errorf("%w: row %d contains invalid utf-8", ErrInvalidSnapshot, i)
		}
	}
	if s.Cursor != nil {
		if s.Cursor.Column < 0 || s.Cursor.Column > ttyapi.MaxViewportDimension ||
			s.Cursor.Row < 0 || s.Cursor.Row > ttyapi.MaxViewportDimension {
			return fmt.Errorf("%w: cursor coordinates (%d, %d) out of range", ErrInvalidSnapshot, s.Cursor.Column, s.Cursor.Row)
		}
	}
	return nil
}

func validateResize(w, h int) error {
	return ttyapi.ValidateViewportSize(w, h)
}
