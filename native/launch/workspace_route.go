//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"fmt"
	"io"

	"github.com/wippyai/bee/native/client/hive"
)

// workspacePage is how many workspaces one `bee workspace list` prints.
const workspacePage = 50

// runWorkspace performs one `bee workspace` command against the owner's
// workspace catalog and prints its answer.
func runWorkspace(ctx context.Context, out io.Writer, catalog *hive.Workspaces, command workspaceCommand) error {
	switch command.verb {
	case workspaceRoots:
		roots, err := catalog.Roots(ctx)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintln(out, "ROOT  ACCESS"); err != nil {
			return err
		}
		for _, root := range roots {
			if _, err := fmt.Fprintf(out, "%s  %s\n", root.Ref, root.Access); err != nil {
				return err
			}
		}
		return nil
	case workspaceList:
		state := "active"
		if command.archived {
			state = "archived"
		}
		page, err := catalog.List(ctx, state, command.after, workspacePage)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintf(out, "%-32s  %-8s  %s  %s\n", "WORKSPACE", "STATE", "FOLDER", "LABEL"); err != nil {
			return err
		}
		for _, row := range page.Items {
			if err := printWorkspace(out, "", row); err != nil {
				return err
			}
		}
		if page.Next != "" {
			_, err := fmt.Fprintf(out, "NEXT %s\n", page.Next)
			return err
		}
		return nil
	case workspaceCreate:
		row, err := catalog.Create(ctx, hive.NewWorkspace{Label: command.label, Root: command.root, Subpath: command.path, CreateDirectory: command.newFolder})
		if err != nil {
			return err
		}
		return printWorkspace(out, "Created ", row)
	case workspaceArchive:
		row, err := catalog.Archive(ctx, command.id)
		if err != nil {
			return err
		}
		return printWorkspace(out, "Archived ", row)
	case workspaceRestore:
		row, err := catalog.Restore(ctx, command.id)
		if err != nil {
			return err
		}
		return printWorkspace(out, "Restored ", row)
	}
	return fmt.Errorf("bee workspace %s is not a catalog command", command.verb)
}

func printWorkspace(out io.Writer, verb string, row hive.Workspace) error {
	_, err := fmt.Fprintf(out, "%s%-32s  %-8s  %s  %s\n", verb, row.ID, row.State, row.Folder(), row.Label)
	return err
}
