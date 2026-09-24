//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package session

import (
	"errors"
	"strings"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
	tty "github.com/wippyai/runtime/api/tty"
)

func press(p *picker, key, keyType string) pickerOutcome {
	return p.key(tty.Event{Type: "key", Key: key, KeyType: keyType, Action: "press"})
}

func page(ids ...string) hive.DesktopCatalog {
	catalog := hive.DesktopCatalog{}
	for _, id := range ids {
		catalog.Workspaces = append(catalog.Workspaces, hive.WorkspaceSummary{ID: strings.Repeat(id, 32), Label: "Workspace " + id})
	}
	return catalog
}

func TestPickerChoosesTheSelectedWorkspaceOfTheCurrentPage(t *testing.T) {
	p := &picker{}
	p.apply(page("a", "b", "c"), nil)
	press(p, "down", "down")
	press(p, "down", "down")
	press(p, "down", "down")
	if p.selected != 2 {
		t.Fatalf("selection ran past the page: %d", p.selected)
	}
	press(p, "up", "up")
	if outcome := press(p, "enter", "enter"); outcome != pickerChosen || p.chosen() != strings.Repeat("b", 32) {
		t.Fatalf("outcome=%v chosen=%q", outcome, p.chosen())
	}
	empty := &picker{}
	empty.apply(hive.DesktopCatalog{}, nil)
	if press(empty, "enter", "enter") != pickerContinue {
		t.Fatal("an empty page chose a workspace")
	}
}

func TestPickerPagesForwardAndBackByCursor(t *testing.T) {
	p := &picker{}
	first := page("a", "b")
	first.Next = "cursor-2"
	p.apply(first, nil)
	if press(p, "pgup", "pgup") != pickerContinue {
		t.Fatal("paged back from the first page")
	}
	if press(p, "pgdown", "pgdown") != pickerReload || p.after != "cursor-2" || len(p.back) != 1 {
		t.Fatalf("forward page: %+v", p)
	}
	p.apply(page("c"), nil)
	if press(p, "pgdown", "pgdown") != pickerContinue {
		t.Fatal("paged past the last page")
	}
	if press(p, "pgup", "pgup") != pickerReload || p.after != "" || len(p.back) != 0 {
		t.Fatalf("back page: %+v", p)
	}
}

func TestPickerSearchRunsALabelPrefixFromItsFirstPage(t *testing.T) {
	p := &picker{after: "cursor-3", back: []string{"", "cursor-2"}}
	p.apply(page("a"), nil)
	press(p, "/", "")
	for _, key := range []string{"p", "r", "x"} {
		press(p, key, "")
	}
	press(p, "backspace", "backspace")
	p.key(tty.Event{Type: "key", Key: "\x1b", Action: "press"})
	if p.query != "pr" || !p.editing {
		t.Fatalf("search text: %q editing=%v", p.query, p.editing)
	}
	if press(p, "enter", "enter") != pickerReload || p.editing || p.after != "" || len(p.back) != 0 {
		t.Fatalf("search did not restart paging: %+v", p)
	}
	press(p, "/", "")
	if press(p, "esc", "esc") != pickerContinue || p.editing {
		t.Fatal("escape did not leave the search field")
	}
	if press(p, "esc", "esc") != pickerClosed {
		t.Fatal("escape did not leave the picker")
	}
	if (&picker{}).key(tty.Event{Type: "key", Key: "q", Ctrl: true, Action: "press"}) != pickerClosed {
		t.Fatal("Ctrl+Q did not leave the picker")
	}
}

func TestPickerKeepsItsPageWhenTheCatalogIsUnavailable(t *testing.T) {
	p := &picker{}
	p.apply(page("a", "b"), nil)
	p.apply(hive.DesktopCatalog{}, errors.New("owner stopped"))
	if len(p.page) != 2 || !strings.Contains(p.status, "owner stopped") {
		t.Fatalf("page=%d status=%q", len(p.page), p.status)
	}
	rows := p.rows(60, 10)
	if len(rows) != 10 || !strings.Contains(rows[len(rows)-1], "owner stopped") {
		t.Fatalf("rows: %q", rows)
	}
	for _, row := range rows {
		if len([]rune(row)) != 60 {
			t.Fatalf("row width %d: %q", len([]rune(row)), row)
		}
	}
}
