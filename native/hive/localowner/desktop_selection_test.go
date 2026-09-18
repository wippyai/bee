//go:build meshclient && physicalclient && !windows

// SPDX-License-Identifier: MIT
package localowner_test

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
	lua "github.com/wippyai/go-lua"
	tty "github.com/wippyai/runtime/api/tty"
	ttymodule "github.com/wippyai/runtime/runtime/lua/modules/tty"
	"github.com/wippyai/runtime/service/terminal"
)

// This gate requires one runtime with both launch and selection/clipboard APIs.
// It must fail, not fall back to a local-only display, when those APIs are absent.
func TestNativeClientSelectionComposition(t *testing.T) {
	if os.Getenv("BEE_OWNER_TEST_WIPPY") == "" {
		t.Skip("explicit owner toolchain required")
	}
	module, _ := ttymodule.Module.Build()
	text, ok := module.RawGetString("text").(*lua.LTable)
	missing := []string{}
	if !ok || text.RawGetString("plain") == lua.LNil {
		missing = append(missing, "tty.text.plain")
	}
	if _, ok := any(terminal.NewSurface(io.Discard, tty.SurfaceOptions{})).(interface{ Clipboard(string) error }); !ok {
		missing = append(missing, "physical surface Clipboard")
	}
	if len(missing) != 0 {
		t.Fatalf("selected-window acceptance requires a combined runtime; compiled runtime lacks %s", strings.Join(missing, ", "))
	}
	t.Setenv("BEE_OWNER_TEST_COPY", "1")
	TestFreshClientDesktopComposition(t)
}

func (b *sessionOutput) visual() string {
	b.Lock()
	defer b.Unlock()
	if b.screen == nil {
		return ""
	}
	return b.screen.String()
}

func probeSelectedCopy(ctx context.Context, input *os.File, output *sessionOutput, done <-chan struct{}, failure func() error) error {
	write := func(text string) error { _, err := input.Write([]byte(text)); return err }
	wait := func(marker string) (int, int, error) {
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		for {
			for row, line := range strings.Split(output.visual(), "\n") {
				if column := strings.Index(line, marker); column >= 0 {
					return ansi.StringWidth(line[:column]) + 1, row + 1, nil
				}
			}
			select {
			case <-ctx.Done():
				return 0, 0, fmt.Errorf("selection frame %q missing: %w\n%s", marker, ctx.Err(), output.visual())
			case <-done:
				return 0, 0, fmt.Errorf("selection client exited: %w", failure())
			case <-ticker.C:
			}
		}
	}
	mouse := func(button, x, y int, release bool) string {
		end := "M"
		if release {
			end = "m"
		}
		return fmt.Sprintf("\x1b[<%d;%d;%d%s", button, x, y, end)
	}
	const marker = "BEE_SELECTION_FOREGROUND"
	if err := write("clear; printf 'BEE_SELECTION_%s\\n' FOREGROUND\r"); err != nil {
		return err
	}
	x, y, err := wait(marker)
	if err != nil {
		return err
	}
	if err := write(mouse(2, x, y, false) + mouse(2, x, y, true)); err != nil {
		return err
	}
	mx, my, err := wait("Select text")
	if err != nil {
		return err
	}
	if err := write(mouse(0, mx, my, false) + mouse(0, mx, my, true)); err != nil {
		return err
	}
	if _, _, err := wait("drag to select"); err != nil {
		return err
	}
	start := len(output.text())
	// No settling sleep: Copy must remain behind the selection's release event.
	if err := write(mouse(0, x, y, false) + mouse(32, x+len(marker)-1, y, false) + mouse(0, x+len(marker)-1, y, true) + "\x03"); err != nil {
		return err
	}
	pattern := regexp.MustCompile("\x1b\\]52;c;([A-Za-z0-9+/=]*)\x07")
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		matches := pattern.FindAllStringSubmatch(output.text()[start:], -1)
		if len(matches) > 0 {
			decoded, err := base64.StdEncoding.Strict().DecodeString(matches[0][1])
			if err != nil || len(matches) != 1 || string(decoded) != marker {
				return fmt.Errorf("incorrect clipboard selection: %q, copies=%d, decode=%v", decoded, len(matches), err)
			}
			break
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("selected-window clipboard output missing: %w\n%s", ctx.Err(), output.visual())
		case <-done:
			if failure() != nil {
				return fmt.Errorf("selected-window copy ended client: %w", failure())
			}
			return errors.New("selected-window copy ended client without clipboard output")
		case <-ticker.C:
		}
	}
	if err := write("printf 'BEE_COPY_%s_OK\\n' resumed\r"); err != nil {
		return err
	}
	if _, _, err := wait("BEE_COPY_resumed_OK"); err != nil {
		return err
	}
	if len(pattern.FindAllStringSubmatch(output.text()[start:], -1)) != 1 {
		return errors.New("clipboard output repeated after ordinary input")
	}
	return nil
}
