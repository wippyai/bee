//go:build meshclient

// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"errors"
)

const DesktopLaunchOperation = "bee.desktop:launch"

// DesktopCommand carries literal values. The owner resolves its admitted catalog.
type DesktopCommand struct {
	Name      string   `json:"name"`
	Arguments []string `json:"arguments"`
}

func (c DesktopCommand) Valid() bool {
	if len(c.Name) == 0 || len(c.Name) > 40 || len(c.Arguments) > 16 {
		return false
	}
	for i, b := range []byte(c.Name) {
		if !(b >= 'a' && b <= 'z') && !(i > 0 && (b >= '0' && b <= '9' || b == '_' || b == '-')) {
			return false
		}
	}
	total := 0
	for _, value := range c.Arguments {
		if len(value) > 1024 {
			return false
		}
		total += len(value)
		if total > 8192 {
			return false
		}
		for _, b := range []byte(value) {
			if b < 32 || b == 127 {
				return false
			}
		}
	}
	return true
}

// LaunchedApplication identifies the broker's committed open result, not a PID.
type LaunchedApplication struct {
	ID       string `json:"id"`
	Instance string `json:"instance_id"`
}

// Launch requires the existing controller session; it never retries a mutation.
func (d *Desktop) Launch(ctx context.Context, key string, mounted DesktopMount, command DesktopCommand) (LaunchedApplication, error) {
	if d == nil || !mounted.Selection.valid() || mounted.Selection.Execution != d.execution || mounted.owner != d.owner ||
		!samePID(mounted.Recipient, d.recipient) || !identifier(mounted.Session) || !live(mounted.lifetime) || mounted.Mode != Control || !command.Valid() {
		return LaunchedApplication{}, errors.New("invalid command or unavailable desktop controller")
	}
	// Lua requires an explicit dense argument vector, including for no arguments.
	command.Arguments = append([]string{}, command.Arguments...)
	input := struct {
		DesktopSelection
		Session string `json:"session_id"`
		DesktopCommand
	}{mounted.Selection, mounted.Session, command}
	reply, err := d.call(ctx, DesktopLaunchOperation, key, input)
	if err != nil {
		return LaunchedApplication{}, err
	}
	result, err := DecodeLaunchedApplication(reply, mounted)
	if err != nil {
		return LaunchedApplication{}, &UnknownOutcome{Operation: DesktopLaunchOperation, Key: key, Cause: err}
	}
	return result, nil
}

func DecodeLaunchedApplication(reply Reply, mounted DesktopMount) (LaunchedApplication, error) {
	if !desktopValue(reply) || !mounted.Selection.valid() || !identifier(mounted.Session) || !live(mounted.lifetime) {
		return LaunchedApplication{}, ErrDesktopReply
	}
	var wire struct {
		DesktopSelection
		Session string `json:"session_id"`
		LaunchedApplication
	}
	if !exactDesktopFields(reply.Value, "owner_execution", "workspace_id", "desktop_id", "session_id", "id", "instance_id") ||
		strict(reply.Value, &wire) != nil || wire.DesktopSelection != mounted.Selection || wire.Session != mounted.Session ||
		!identifier(wire.ID) || len(wire.ID) > 80 || !identifier(wire.Instance) || len(wire.Instance) > 80 || !live(reply.lifetime) {
		return LaunchedApplication{}, ErrDesktopReply
	}
	return wire.LaunchedApplication, nil
}
