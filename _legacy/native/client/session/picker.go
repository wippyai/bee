//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package session

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"

	"github.com/wippyai/bee/native/client/hive"
	tty "github.com/wippyai/runtime/api/tty"
	"github.com/wippyai/runtime/service/terminal"
)

// ErrPickerClosed means the person left the workspace picker without choosing.
var ErrPickerClosed = errors.New("workspace picker closed")

// catalogPage reads one page of the node workspace catalog.
type catalogPage func(context.Context, hive.CatalogQuery) (hive.DesktopCatalog, error)

// picker holds one catalog page and the cursors back to earlier pages, never
// the whole catalog. Typing after "/" edits a label prefix; Enter runs it
// from its first page.
type picker struct {
	query    string
	editing  bool
	after    string
	back     []string
	page     []hive.WorkspaceSummary
	next     string
	selected int
	status   string
}

type pickerOutcome int

const (
	pickerContinue pickerOutcome = iota
	pickerReload
	pickerChosen
	pickerClosed
)

func (p *picker) apply(catalog hive.DesktopCatalog, err error) {
	if err != nil {
		p.status = "Catalog unavailable: " + err.Error()
		return
	}
	p.page, p.next, p.status = catalog.Workspaces, catalog.Next, ""
	if p.selected >= len(p.page) {
		p.selected = 0
	}
}

func (p *picker) chosen() string {
	if p.selected < 0 || p.selected >= len(p.page) {
		return ""
	}
	return p.page[p.selected].ID
}

// key applies one key press. Only pickerReload asks for a catalog read.
func (p *picker) key(event tty.Event) pickerOutcome {
	if event.Type != "key" || event.Action == "release" {
		return pickerContinue
	}
	if event.Ctrl && (event.Key == "q" || event.Key == "c") {
		return pickerClosed
	}
	if p.editing {
		switch event.KeyType {
		case "enter":
			p.editing, p.after, p.back, p.selected = false, "", nil, 0
			return pickerReload
		case "esc":
			p.editing = false
		case "backspace":
			if p.query != "" {
				_, size := utf8.DecodeLastRuneInString(p.query)
				p.query = p.query[:len(p.query)-size]
			}
		default:
			if event.KeyType == "" && !event.Ctrl && !event.Alt && event.Key != "" && printableLabel(event.Key) &&
				len(p.query)+len(event.Key) <= 120 {
				p.query += event.Key
			}
		}
		return pickerContinue
	}
	switch event.KeyType {
	case "up":
		if p.selected > 0 {
			p.selected--
		}
	case "down":
		if p.selected+1 < len(p.page) {
			p.selected++
		}
	case "pgdown":
		if p.next != "" {
			p.back = append(p.back, p.after)
			p.after, p.selected = p.next, 0
			return pickerReload
		}
	case "pgup":
		if len(p.back) > 0 {
			p.after = p.back[len(p.back)-1]
			p.back, p.selected = p.back[:len(p.back)-1], 0
			return pickerReload
		}
	case "enter":
		if p.chosen() != "" {
			return pickerChosen
		}
	case "esc":
		return pickerClosed
	default:
		if event.Key == "/" && !event.Ctrl && !event.Alt {
			p.editing = true
		}
	}
	return pickerContinue
}

func printableLabel(s string) bool {
	for _, c := range s {
		if c < 32 || c == 127 {
			return false
		}
	}
	return true
}

func clip(s string, width int) string {
	if width <= 0 {
		return ""
	}
	count := 0
	for index := range s {
		if count == width {
			return s[:index]
		}
		count++
	}
	return s
}

// rows draws the picker in width x height cells.
func (p *picker) rows(width, height int) []string {
	if width < 20 {
		width = 20
	}
	if height < 6 {
		height = 6
	}
	rows := []string{clip(" Bee workspaces  ↑↓ select · Enter open · / search · PgUp/PgDn page · Esc leave", width)}
	search := " Search: " + p.query
	if p.editing {
		search += "▏"
	}
	rows = append(rows, clip(search, width), "")
	visible := height - 5
	start := 0
	if p.selected >= visible {
		start = p.selected - visible + 1
	}
	if len(p.page) == 0 {
		rows = append(rows, " No workspaces match")
	}
	for index := start; index < len(p.page) && len(rows) < 3+visible; index++ {
		item := p.page[index]
		marker, served := "  ", " "
		if index == p.selected {
			marker = "> "
		}
		if item.Served {
			served = "●"
		}
		label := item.Label
		if label == "" {
			label = "(unnamed)"
		}
		rows = append(rows, clip(fmt.Sprintf(" %s%s %s  %s", marker, served, label, item.ID[:8]), width))
	}
	for len(rows) < height-1 {
		rows = append(rows, "")
	}
	footer := fmt.Sprintf(" Page %d", len(p.back)+1)
	if p.next != "" {
		footer += " · more"
	}
	if p.status != "" {
		footer += " · " + p.status
	}
	rows = append(rows, clip(footer, width))
	for index, row := range rows {
		if count := utf8.RuneCountInString(row); count < width {
			rows[index] = row + strings.Repeat(" ", width-count)
		}
	}
	return rows
}

// pick shows the node's workspaces in the physical terminal and returns the
// chosen workspace. It reads one catalog page at a time.
func pick(ctx context.Context, list catalogPage, stdin *os.File, stdout io.Writer) (result string, err error) {
	state := &picker{}
	state.apply(list(ctx, hive.CatalogQuery{}))
	events := make(chan tty.Event, 64)
	width, height := 100, 30
	surface := terminal.NewSurface(stdout, tty.SurfaceOptions{AlternateScreen: true, HideCursor: true, Synchronized: true})
	defer func() { err = errors.Join(err, surface.Close()) }()
	reader := terminal.NewEventInputReader(stdin, stdout, terminal.NewRawManager(stdin), func(event tty.Event) {
		select {
		case events <- event:
		default:
		}
	})
	if err := reader.Start(); err != nil {
		return "", err
	}
	defer func() { err = errors.Join(err, reader.Stop()) }()
	for {
		if _, err := surface.Present(tty.Frame{Rows: state.rows(width, height)}); err != nil {
			return "", err
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-reader.Done():
			if err := reader.Err(); err != nil {
				return "", err
			}
			return "", ErrPickerClosed
		case event := <-events:
			if event.Type == "start" || event.Type == "resize" {
				if event.Width > 0 && event.Height > 0 {
					width, height = event.Width, event.Height
				}
				continue
			}
			switch state.key(event) {
			case pickerReload:
				state.apply(list(ctx, hive.CatalogQuery{Label: state.query, After: state.after}))
			case pickerChosen:
				return state.chosen(), nil
			case pickerClosed:
				return "", ErrPickerClosed
			}
		}
	}
}
