//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/wippyai/bee/native/client/session"
	"github.com/wippyai/bee/native/hive/rendezvous"
	app "github.com/wippyai/runtime/cmd/app"
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

func (c clientSelection) list(ctx context.Context, launch app.Launch) error {
	if err := c.validate(ctx, launch); err != nil {
		return err
	}
	store, err := rendezvous.New(filepath.Join(launch.State, rendezvous.DirectoryName))
	if err != nil {
		return err
	}
	if _, err := store.Read(ctx); errors.Is(err, os.ErrNotExist) {
		return errors.New("No running Bee to list; start bee first")
	} else if err != nil {
		return err
	}
	catalog, err := session.List(ctx, filepath.Join(launch.State, rendezvous.DirectoryName))
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
