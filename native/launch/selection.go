//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"

	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/rendezvous"
	"github.com/wippyai/bee/native/internal/privatefile"
	application "github.com/wippyai/runtime/api/application"
)

func parseSelection(workspace, desktop string) (session.Selection, error) {
	for _, id := range []string{workspace, desktop} {
		decoded, err := hex.DecodeString(id)
		if err != nil || len(decoded) != 16 || hex.EncodeToString(decoded) != id {
			return session.Selection{}, errors.New("workspace and display must be 32 lowercase hexadecimal characters")
		}
	}
	return session.Selection{Workspace: workspace, Desktop: desktop}, nil
}

func (c Client) list(ctx context.Context, request application.LaunchRequest) error {
	if err := c.validate(ctx, request); err != nil {
		return err
	}
	if err := privatefile.EnsurePrivateDir(request.StateDir); err != nil {
		return err
	}
	busy, err := ownerLockBusy(request.StateDir)
	if err != nil {
		return err
	}
	if !busy {
		return errors.New("No running Bee to list; start bee first")
	}
	catalog, err := session.List(ctx, filepath.Join(request.StateDir, rendezvous.DirectoryName))
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintln(c.Stdout, "WORKSPACE                         DISPLAY                           DEFAULT"); err != nil {
		return err
	}
	for _, workspace := range catalog.Workspaces {
		for _, desktop := range workspace.Desktops {
			marker := ""
			if desktop.IsDefault {
				marker = "yes"
			}
			if _, err := fmt.Fprintf(c.Stdout, "%s  %s  %s\n", workspace.ID, desktop.ID, marker); err != nil {
				return err
			}
		}
	}
	return nil
}
