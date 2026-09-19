//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

// Package launch binds Bee's native client to the runtime application host.
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
	app "github.com/wippyai/runtime/cmd/app"
)

// Client is selected by the compiled host. The host runs it through Plan.Run,
// which the runtime invokes directly without opening the application state.
// The caller owns files and signals. This adapter starts no owner, opens no
// database and retries no input.
type Client struct {
	AttachOnly bool // Explicit display client: never start a workspace node.
	Command    string
	Selection  session.Selection
	Launch     *hive.DesktopCommand
	Mode       hive.DesktopMode
	Stdin      *os.File
	Stdout     io.Writer
}

func (c Client) Attach(ctx context.Context, launch app.Launch) error {
	if err := c.validate(ctx, launch); err != nil {
		return err
	}
	return session.Join(ctx, session.Config{
		Directory: filepath.Join(launch.State, rendezvous.DirectoryName),
		Selection: c.Selection, Mode: c.Mode, Command: c.Launch,
	}, c.Stdin, c.Stdout)
}

func (c Client) validate(ctx context.Context, launch app.Launch) error {
	if ctx == nil || launch.Op != app.OpRun ||
		c.Command == "" || launch.Command != c.Command || len(launch.Args) != 0 ||
		!filepath.IsAbs(launch.State) || c.Stdin == nil || c.Stdout == nil ||
		(c.Mode != hive.Control && c.Mode != hive.Observe) ||
		((c.Selection.Workspace == "") != (c.Selection.Desktop == "")) ||
		(c.Launch != nil && (!c.Launch.Valid() || c.Mode != hive.Control)) {
		return errors.New("unsupported Bee client attachment request")
	}
	return ctx.Err()
}
