//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

// Package launch binds Bee's native client to the runtime application launcher.
package launch

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/wippyai/bee/native/client/hive"
	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/rendezvous"
	application "github.com/wippyai/runtime/api/application"
)

// Client is selected by the compiled host. Attach is a LaunchPlan.Attach callback;
// the runtime invokes it only after its actual application lock is busy, before
// deployment or application data binding. The caller owns files and signals.
// This adapter starts no owner, opens no database and retries no input.
type Client struct {
	Command   string
	Selection session.Selection
	Mode      hive.DesktopMode
	Stdin     *os.File
	Stdout    io.Writer
}

func (c Client) Attach(ctx context.Context, request application.LaunchRequest) error {
	if err := c.validate(ctx, request); err != nil {
		return err
	}
	return session.Join(ctx, session.Config{
		Directory: filepath.Join(request.StateDir, rendezvous.DirectoryName),
		Selection: c.Selection, Mode: c.Mode,
	}, c.Stdin, c.Stdout)
}

func (c Client) validate(ctx context.Context, request application.LaunchRequest) error {
	if ctx == nil || request.Operation != application.RunApplication || request.Base ||
		c.Command == "" || request.Command != c.Command || len(request.Arguments) != 0 ||
		!filepath.IsAbs(request.StateDir) || c.Stdin == nil || c.Stdout == nil ||
		(c.Mode != hive.Control && c.Mode != hive.Observe) ||
		((c.Selection.Workspace == "") != (c.Selection.Desktop == "")) {
		return errors.New("unsupported Bee client attachment request")
	}
	return ctx.Err()
}
