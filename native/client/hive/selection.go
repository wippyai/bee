//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"errors"
	"time"
	"unicode/utf8"
)

const DesktopCopy = "bee.desktop:copy"

// SelectionText is an explicit copy response, never retained viewport content.
// Selected=false means Ctrl+C should retain its ordinary application behavior.
type SelectionText struct {
	Selected bool
	Text     string
}

// Copy requests the current selection for this exact admitted session. It does
// not write a clipboard or retry an uncertain response. The physical client
// calls it only for an explicit user copy action.
func (d *Desktop) Copy(ctx context.Context, key string, mounted DesktopMount) (SelectionText, error) {
	if d == nil || !mounted.Selection.valid() || mounted.Selection.Execution != d.execution || mounted.owner != d.owner ||
		!samePID(mounted.Recipient, d.recipient) || !identifier(mounted.Session) || !live(mounted.lifetime) ||
		!time.Now().Before(mounted.Expires) {
		return SelectionText{}, errors.New("copy session unavailable or belongs to another recipient")
	}
	input := struct {
		DesktopSelection
		Session string `json:"session_id"`
	}{mounted.Selection, mounted.Session}
	reply, err := d.call(ctx, DesktopCopy, key, input)
	if err != nil {
		return SelectionText{}, err
	}
	selected, err := DecodeSelectionText(reply, mounted, time.Now())
	if err != nil {
		return SelectionText{}, &UnknownOutcome{Operation: DesktopCopy, Key: key, Cause: err}
	}
	return selected, nil
}

func DecodeSelectionText(reply Reply, mounted DesktopMount, now time.Time) (SelectionText, error) {
	if !desktopValue(reply) || !mounted.Selection.valid() || !identifier(mounted.Session) ||
		!live(mounted.lifetime) || now.IsZero() || !now.Before(mounted.Expires) {
		return SelectionText{}, ErrDesktopReply
	}
	var wire struct {
		DesktopSelection
		Session  string `json:"session_id"`
		Selected bool   `json:"selected"`
		Text     string `json:"text"`
	}
	if !exactDesktopFields(reply.Value, "owner_execution", "workspace_id", "desktop_id", "session_id", "selected", "text") ||
		strict(reply.Value, &wire) != nil || wire.DesktopSelection != mounted.Selection || wire.Session != mounted.Session ||
		!plainSelection(wire.Text) || (!wire.Selected && wire.Text != "") || !live(reply.lifetime) || !live(mounted.lifetime) {
		return SelectionText{}, ErrDesktopReply
	}
	return SelectionText{Selected: wire.Selected, Text: wire.Text}, nil
}

func plainSelection(text string) bool {
	if len(text) > 8192 || !utf8.ValidString(text) {
		return false
	}
	for _, c := range text {
		if (c < 32 && c != '\t' && c != '\n') || c == 127 {
			return false
		}
	}
	return true
}
