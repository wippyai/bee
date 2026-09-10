//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package session

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/wippyai/bee/native/client/hive"
)

type desktopAdmission interface {
	Attach(context.Context, string, string, string, hive.DesktopMode) (hive.DesktopMount, error)
	Create(context.Context, string, string) (hive.DesktopSelection, error)
}

// A BUSY reply can mean activation, storage or cleanup is in progress.
// Only the contract's definite controller collision permits selecting
// a different desktop. An uncertain result must never enter this fallback.
func controlledDesktop(err error) bool {
	var unknown *hive.UnknownOutcome
	if errors.As(err, &unknown) {
		return false
	}
	var refused *hive.Rejected
	return errors.As(err, &refused) && refused.Fault.Code == "DESKTOP_CONTROLLED"
}

// attachDesktop chooses within one already-selected workspace. The default gets
// first refusal; existing additional identities are tried in stable identity
// order. Control admission is the atomic availability check, not catalog data.
// Explicit selections and observers never fall back or allocate another desktop.
func attachDesktop(ctx context.Context, client desktopAdmission, catalog hive.DesktopCatalog, selection Selection, mode hive.DesktopMode) (hive.DesktopMount, error) {
	selected, err := selectDesktop(catalog, selection)
	if err != nil {
		return hive.DesktopMount{}, err
	}
	mounted, err := client.Attach(ctx, "session-attach", selected.Workspace, selected.Desktop, mode)
	if err == nil || selection != (Selection{}) || mode != hive.Control || !controlledDesktop(err) {
		return mounted, err
	}
	var alternatives []string
	for _, workspace := range catalog.Workspaces {
		if workspace.ID != selected.Workspace {
			continue
		}
		for _, desktop := range workspace.Desktops {
			if desktop.ID != selected.Desktop {
				alternatives = append(alternatives, desktop.ID)
			}
		}
	}
	sort.Strings(alternatives)
	for index, desktop := range alternatives {
		if err := ctx.Err(); err != nil {
			return hive.DesktopMount{}, err
		}
		mounted, err := client.Attach(ctx, fmt.Sprintf("session-attach-alternative-%d", index), selected.Workspace, desktop, mode)
		if err == nil || !controlledDesktop(err) {
			return mounted, err
		}
	}
	if err := ctx.Err(); err != nil {
		return hive.DesktopMount{}, err
	}
	var identity [16]byte
	if _, err := rand.Read(identity[:]); err != nil {
		return hive.DesktopMount{}, err
	}
	desktop := hex.EncodeToString(identity[:])
	// Keep one identity for the whole invocation. A refused/unknown allocation
	// ends admission; it never allocates a replacement or steals another mount.
	if err := createDesktop(ctx, client, selected.Workspace, desktop); err != nil {
		return hive.DesktopMount{}, fmt.Errorf("create desktop %s: %w", desktop, err)
	}
	return client.Attach(ctx, "session-attach-created", selected.Workspace, desktop, mode)
}

// Catalog contention is a definite refusal. Retry only that refusal, always with
// the same allocation identity and inside the admission deadline. Capacity,
// denial, malformed success and uncertain outcomes end the attempt.
func createDesktop(ctx context.Context, client desktopAdmission, workspace, desktop string) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		_, err := client.Create(ctx, workspace, desktop)
		if err == nil {
			return nil
		}
		var unknown *hive.UnknownOutcome
		var refused *hive.Rejected
		if errors.As(err, &unknown) || !errors.As(err, &refused) || refused.Fault.Code != "BUSY" {
			return err
		}
		timer := time.NewTimer(50 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
