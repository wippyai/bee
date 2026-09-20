// SPDX-License-Identifier: MIT
// Source-free acceptance for the public `bee agent` picker and managed launch.
package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/creack/pty"
	_ "github.com/mattn/go-sqlite3"
	"golang.org/x/sys/unix"
)

const (
	frameStart = "\x1b[?2026h"
	frameEnd   = "\x1b[?2026l"
	frameLimit = 1024 * 1024
	logLimit   = 64 * 1024
)

type observedFrame struct {
	sequence uint64
	text     string
}

type desktop struct {
	cmd      *exec.Cmd
	terminal *os.File
	mu       chan struct{}
	latest   string
	frame    uint64
	history  []observedFrame
	log      []byte
	pending  []byte
	screen   *terminalScreen
	wait     <-chan error
	done     <-chan struct{}
	readDone <-chan struct{}
}

func newDesktop(binary, project, state, home string, extraEnv ...string) (*desktop, error) {
	return newDesktopWithArguments(binary, project, state, home, []string{"agent"}, extraEnv...)
}

func newDesktopWithArguments(binary, project, state, home string, arguments []string, extraEnv ...string) (*desktop, error) {
	if err := os.MkdirAll(state, 0700); err != nil {
		return nil, fmt.Errorf("create state: %w", err)
	}
	if err := os.MkdirAll(home, 0700); err != nil {
		return nil, fmt.Errorf("create home: %w", err)
	}
	env := filteredEnvironment()
	env = append(env,
		"TERM=xterm-256color",
		"HOME="+home,
		"PATH="+filepath.Join(project, "bin")+":/usr/bin:/bin",
		"XDG_CONFIG_HOME="+filepath.Join(home, ".config"),
	)
	cmd := exec.Command(binary, append([]string{"--state", state}, arguments...)...)
	cmd.Dir = project
	cmd.Env = append(env, extraEnv...)
	terminal, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 30, Cols: 100})
	if err != nil {
		return nil, fmt.Errorf("start Bee PTY: %w", err)
	}
	d := &desktop{cmd: cmd, terminal: terminal, mu: make(chan struct{}, 1), screen: newTerminalScreen(100, 30)}
	wait := make(chan error, 1)
	done := make(chan struct{})
	go func() {
		wait <- cmd.Wait()
		close(done)
	}()
	d.wait = wait
	d.done = done
	readDone := make(chan struct{})
	d.readDone = readDone
	go d.readOutput(readDone)
	return d, nil
}

func filteredEnvironment() []string {
	remove := map[string]bool{
		"BEE_RUNTIME": true, "BEE_BINARY": true, "USER": true,
		"CODEX_HOME": true, "CLAUDE_CONFIG_DIR": true, "GROK_HOME": true,
		"CLAUDE_BIN": true, "CLAUDE_LOGIN_FILE": true, "CLAUDE_CREDENTIAL_ENV": true,
		"AGY_BIN": true, "AGY_LOGIN_FILE": true, "AGY_MODEL": true,
		"ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true,
		"ANTHROPIC_CUSTOM_HEADERS": true, "CLAUDE_CODE_OAUTH_TOKEN": true,
		"CLAUDE_CODE_USE_BEDROCK": true, "CLAUDE_CODE_USE_VERTEX": true,
		"CLAUDE_CODE_USE_FOUNDRY": true, "OPENAI_API_KEY": true,
		"XAI_API_KEY": true, "GROK_BIN": true, "GROK_LOGIN_FILE": true,
		"GROK_CONFIG_FILE": true, "GROK_MODEL": true,
		"AWS_ACCESS_KEY_ID": true, "AWS_SECRET_ACCESS_KEY": true,
		"AWS_SESSION_TOKEN": true, "AWS_PROFILE": true,
		"AWS_WEB_IDENTITY_TOKEN_FILE": true, "AWS_BEARER_TOKEN_BEDROCK": true,
		"HTTP_PROXY": true, "HTTPS_PROXY": true, "ALL_PROXY": true,
		"http_proxy": true, "https_proxy": true, "all_proxy": true,
		"GEMINI_API_KEY": true, "GOOGLE_API_KEY": true,
		"GOOGLE_APPLICATION_CREDENTIALS": true, "GOOGLE_GENAI_USE_VERTEXAI": true,
		"XDG_CACHE_HOME": true, "XDG_DATA_HOME": true,
		"XDG_RUNTIME_DIR": true, "XDG_STATE_HOME": true,
		"BEE_WORKSPACE_DB": true, "BEE_THREADS_DB": true, "BEE_APPROVALS_DB": true,
		"BEE_RESOURCES_DB": true, "BEE_CREDENTIALS_DB": true, "BEE_PLACEMENT_DB": true,
		"BEE_GATEWAY_DB": true, "BEE_NODE_DB": true, "BEE_GOVERNANCE_DB": true, "BEE_SYNC_DB": true,
		"BEE_CLIENT_DB": true, "BEE_PLACEMENT_ROOT": true,
	}
	result := make([]string, 0, len(os.Environ())+5)
	for _, value := range os.Environ() {
		name, _, ok := strings.Cut(value, "=")
		if !ok || remove[name] {
			continue
		}
		result = append(result, value)
	}
	return result
}

func (d *desktop) readOutput(done chan<- struct{}) {
	defer close(done)
	buffer := make([]byte, 32*1024)
	for {
		n, err := d.terminal.Read(buffer)
		if n > 0 {
			d.mu <- struct{}{}
			d.log = appendTail(d.log, buffer[:n], logLimit)
			d.pending = append(d.pending, buffer[:n]...)
			d.consumeFrames()
			<-d.mu
		}
		if err != nil {
			return
		}
	}
}

func appendTail(existing, addition []byte, limit int) []byte {
	if len(addition) >= limit {
		return append([]byte(nil), addition[len(addition)-limit:]...)
	}
	if excess := len(existing) + len(addition) - limit; excess > 0 {
		existing = append([]byte(nil), existing[excess:]...)
	}
	return append(existing, addition...)
}

func (d *desktop) consumeFrames() {
	if d.screen == nil {
		d.screen = newTerminalScreen(100, 30)
	}
	for {
		start := bytes.Index(d.pending, []byte(frameStart))
		if start < 0 {
			keep := len(frameStart) - 1
			if len(d.pending) > keep {
				d.pending = append([]byte(nil), d.pending[len(d.pending)-keep:]...)
			}
			return
		}
		if start > 0 {
			d.pending = d.pending[start:]
		}
		end := bytes.Index(d.pending[len(frameStart):], []byte(frameEnd))
		if end < 0 {
			if len(d.pending) > frameLimit {
				d.pending = append([]byte(nil), d.pending[len(d.pending)-frameLimit:]...)
			}
			return
		}
		contentEnd := len(frameStart) + end
		d.screen.apply(d.pending[len(frameStart):contentEnd])
		d.latest = d.screen.render()
		d.frame++
		d.history = append(d.history, observedFrame{sequence: d.frame, text: d.latest})
		if len(d.history) > 32 {
			d.history = d.history[len(d.history)-32:]
		}
		d.pending = append([]byte(nil), d.pending[contentEnd+len(frameEnd):]...)
	}
}

// terminalScreen is the bounded current viewport. Synchronized presenter
// frames contain terminal updates, not necessarily full repaints, so retaining
// this fixed-size screen is necessary to keep unchanged rows truthful while
// applying cursor-positioned edits and erases.
type terminalScreen struct {
	width, height  int
	rows           [][]rune
	x, y           int
	savedX, savedY int
}

func newTerminalScreen(width, height int) *terminalScreen {
	s := &terminalScreen{width: width, height: height, rows: make([][]rune, height)}
	for row := range s.rows {
		s.rows[row] = make([]rune, width)
		for col := range s.rows[row] {
			s.rows[row][col] = ' '
		}
	}
	return s
}

func (s *terminalScreen) clampCursor() {
	if s.x < 0 {
		s.x = 0
	}
	if s.y < 0 {
		s.y = 0
	}
	if s.x > s.width {
		s.x = s.width
	}
	if s.y >= s.height {
		s.y = s.height - 1
	}
}

func (s *terminalScreen) clearCell(row, col int) {
	if row >= 0 && row < s.height && col >= 0 && col < s.width {
		s.rows[row][col] = ' '
	}
}

func (s *terminalScreen) clearLine(mode int) {
	s.clampCursor()
	start, end := 0, s.width-1
	switch mode {
	case 0:
		start = s.x
	case 1:
		end = s.x
	case 2:
		// The whole row is cleared.
	}
	for col := start; col <= end; col++ {
		s.clearCell(s.y, col)
	}
}

func (s *terminalScreen) clearDisplay(mode int) {
	s.clampCursor()
	start, end := 0, s.height*s.width-1
	switch mode {
	case 0:
		start = s.y*s.width + s.x
	case 1:
		end = s.y*s.width + s.x
	case 2, 3:
		// The whole viewport is cleared.
	}
	for offset := start; offset <= end; offset++ {
		s.clearCell(offset/s.width, offset%s.width)
	}
}

func csiParameters(raw string) []int {
	if len(raw) > 0 && (raw[0] == '?' || raw[0] == '>' || raw[0] == '=') {
		raw = raw[1:]
	}
	if raw == "" {
		return []int{0}
	}
	parts := strings.Split(raw, ";")
	result := make([]int, len(parts))
	for i, part := range parts {
		if part == "" {
			result[i] = 0
			continue
		}
		value := 0
		for _, c := range part {
			if c < '0' || c > '9' {
				value = 0
				break
			}
			value = value*10 + int(c-'0')
			if value > 10000 {
				value = 10000
				break
			}
		}
		result[i] = value
	}
	return result
}

func csiCount(params []int) int {
	if len(params) == 0 || params[0] == 0 {
		return 1
	}
	return params[0]
}

func (s *terminalScreen) csi(raw string, final byte) {
	params := csiParameters(raw)
	first := csiCount(params)
	switch final {
	case 'A':
		s.y -= first
	case 'B', 'e':
		s.y += first
	case 'C', 'a':
		s.x += first
	case 'D':
		s.x -= first
	case 'E':
		s.y += first
		s.x = 0
	case 'F':
		s.y -= first
		s.x = 0
	case 'G', '`':
		s.x = first - 1
	case 'd':
		s.y = first - 1
	case 'H', 'f':
		row, col := 1, 1
		if len(params) > 0 && params[0] != 0 {
			row = params[0]
		}
		if len(params) > 1 && params[1] != 0 {
			col = params[1]
		}
		s.y, s.x = row-1, col-1
	case 'J':
		s.clearDisplay(params[0])
	case 'K':
		s.clearLine(params[0])
	case 'P':
		s.clampCursor()
		n := first
		if n > s.width-s.x {
			n = s.width - s.x
		}
		row := s.rows[s.y]
		copy(row[s.x:], row[s.x+n:])
		for col := s.width - n; col < s.width; col++ {
			row[col] = ' '
		}
	case '@':
		s.clampCursor()
		n := first
		if n > s.width-s.x {
			n = s.width - s.x
		}
		row := s.rows[s.y]
		copy(row[s.x+n:], row[s.x:s.width-n])
		for col := s.x; col < s.x+n; col++ {
			row[col] = ' '
		}
	case 'X':
		s.clampCursor()
		for col := s.x; col < s.x+first && col < s.width; col++ {
			s.clearCell(s.y, col)
		}
	case 'S':
		n := first
		if n > s.height {
			n = s.height
		}
		for i := 0; i < n; i++ {
			copy(s.rows, s.rows[1:])
			s.rows[s.height-1] = make([]rune, s.width)
			for col := range s.rows[s.height-1] {
				s.rows[s.height-1][col] = ' '
			}
		}
	case 'T':
		n := first
		if n > s.height {
			n = s.height
		}
		for i := 0; i < n; i++ {
			s.rows = append([][]rune{make([]rune, s.width)}, s.rows[:s.height-1]...)
			for col := range s.rows[0] {
				s.rows[0][col] = ' '
			}
		}
	case 's':
		s.savedX, s.savedY = s.x, s.y
	case 'u':
		s.x, s.y = s.savedX, s.savedY
	}
	s.clampCursor()
}

func (s *terminalScreen) put(r rune) {
	if s.x >= s.width {
		s.x, s.y = 0, s.y+1
	}
	s.clampCursor()
	s.rows[s.y][s.x] = r
	s.x++
}

func (s *terminalScreen) apply(input []byte) {
	for i := 0; i < len(input); {
		if input[i] == 0x1b {
			i++
			if i >= len(input) {
				break
			}
			switch input[i] {
			case '[':
				i++
				start := i
				for i < len(input) && (input[i] < 0x40 || input[i] > 0x7e) {
					i++
				}
				if i < len(input) {
					s.csi(string(input[start:i]), input[i])
					i++
				}
			case ']', 'P', '^', '_', 'X':
				i++
				for i < len(input) {
					if input[i] == 0x07 {
						i++
						break
					}
					if input[i] == 0x1b && i+1 < len(input) && input[i+1] == '\\' {
						i += 2
						break
					}
					i++
				}
			case '7':
				s.savedX, s.savedY = s.x, s.y
				i++
			case '8':
				s.x, s.y = s.savedX, s.savedY
				i++
			case 'c':
				s.clearDisplay(2)
				s.x, s.y, s.savedX, s.savedY = 0, 0, 0, 0
				i++
			case 'D':
				s.y++
				s.clampCursor()
				i++
			case 'E':
				s.y++
				s.x = 0
				s.clampCursor()
				i++
			case 'M':
				s.y--
				s.clampCursor()
				i++
			default:
				i++
			}
			continue
		}
		switch input[i] {
		case '\r':
			s.x = 0
			i++
		case '\n':
			s.y++
			s.clampCursor()
			i++
		case '\b':
			s.x--
			s.clampCursor()
			i++
		case '\t':
			s.x = (s.x/8 + 1) * 8
			s.clampCursor()
			i++
		case 0x07:
			i++
		default:
			r, size := utf8.DecodeRune(input[i:])
			if size == 0 {
				return
			}
			s.put(r)
			i += size
		}
	}
}

func (s *terminalScreen) render() string {
	last := -1
	rows := make([]string, len(s.rows))
	for row, cells := range s.rows {
		end := len(cells)
		for end > 0 && cells[end-1] == ' ' {
			end--
		}
		rows[row] = string(cells[:end])
		if end > 0 {
			last = row
		}
	}
	if last < 0 {
		return ""
	}
	return strings.Join(rows[:last+1], "\n")
}

// visible removes terminal control sequences while preserving only the text
// in one byte string. It remains useful for callers that need a one-off text
// extraction; consumeFrames uses terminalScreen because frames are deltas.
func (d *desktop) resize(columns, rows uint16) error {
	d.mu <- struct{}{}
	defer func() { <-d.mu }()
	if err := pty.Setsize(d.terminal, &pty.Winsize{Cols: columns, Rows: rows}); err != nil {
		return err
	}
	d.screen = newTerminalScreen(int(columns), int(rows))
	d.latest = ""
	return nil
}

func (d *desktop) snapshot() (string, uint64, []byte) {
	d.mu <- struct{}{}
	defer func() { <-d.mu }()
	return d.latest, d.frame, append([]byte(nil), d.log...)
}

// Readiness is an observed emission after a fence, not a search of only the
// most recent cell delta (which may already omit the readiness text).
func (d *desktop) observed(text string, after uint64) bool {
	d.mu <- struct{}{}
	defer func() { <-d.mu }()
	for _, frame := range d.history {
		if frame.sequence > after && strings.Contains(frame.text, text) {
			return true
		}
	}
	return false
}

func (d *desktop) waitFor(text string, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		_, _, log := d.snapshot()
		if d.observed(text, 0) {
			return nil
		}
		select {
		case err := <-d.wait:
			return fmt.Errorf("Bee exited while waiting for %q: %v\n%s", text, err, string(log))
		case <-deadline.C:
			return fmt.Errorf("timed out waiting for %q\n%s", text, string(log))
		case <-tick.C:
		}
	}
}

func (d *desktop) waitAbsent(text string, previous uint64, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		latest, frame, log := d.snapshot()
		if frame > previous && !strings.Contains(latest, text) {
			return nil
		}
		select {
		case err := <-d.wait:
			return fmt.Errorf("Bee exited while waiting for picker close: %v\n%s", err, string(log))
		case <-deadline.C:
			return fmt.Errorf("picker remained visible after Escape\n%s", string(log))
		case <-tick.C:
		}
	}
}

func (d *desktop) waitForAfter(text string, previous uint64, timeout time.Duration) error {
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		_, _, log := d.snapshot()
		if d.observed(text, previous) {
			return nil
		}
		select {
		case err := <-d.wait:
			return fmt.Errorf("Bee exited while waiting for refreshed %q: %v\n%s", text, err, string(log))
		case <-deadline.C:
			latest, current, _ := d.snapshot()
			return fmt.Errorf("timed out waiting for refreshed %q (after %d, current %d)\n%s", text, previous, current, latest)
		case <-tick.C:
		}
	}
}

func (d *desktop) send(input string) error {
	_, err := io.WriteString(d.terminal, input)
	return err
}

func (d *desktop) quit() error {
	if err := d.send("\x11"); err != nil {
		return err
	}
	select {
	case err := <-d.wait:
		if err != nil {
			return fmt.Errorf("Bee quit: %w", err)
		}
		return nil
	case <-time.After(2 * time.Second):
		return errors.New("Bee quit exceeded 2 seconds")
	}
}

func (d *desktop) close() {
	if d == nil {
		return
	}
	select {
	case <-d.done:
	default:
		if d.cmd.Process != nil {
			_ = d.cmd.Process.Kill()
		}
		select {
		case <-d.wait:
		case <-time.After(2 * time.Second):
		}
	}
	_ = d.terminal.Close()
	select {
	case <-d.readDone:
	case <-time.After(2 * time.Second):
	}
}

type owner struct{ fd int }

func cmdline(pid int) ([]string, error) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return nil, err
	}
	parts := bytes.Split(data, []byte{0})
	args := make([]string, 0, len(parts))
	for _, part := range parts {
		if len(part) != 0 {
			args = append(args, string(part))
		}
	}
	return args, nil
}

func ownerArgsMatch(args []string, binary, state string) bool {
	if len(args) == 0 || args[0] != binary {
		return false
	}
	stateMatch, startMatch := false, false
	for i, arg := range args {
		if arg == state && i > 0 && args[i-1] == "--state" {
			stateMatch = true
		}
		if arg == "start" {
			startMatch = true
		}
	}
	return stateMatch && startMatch
}

func ownerPidfd(pid int, binary, state string) (*owner, error) {
	if runtime.GOOS != "linux" {
		return nil, errors.New("native Agent acceptance requires Linux pidfd cleanup")
	}
	fd, err := unix.PidfdOpen(pid, 0)
	if err != nil {
		return nil, err
	}
	executable, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	args, argsErr := cmdline(pid)
	if err != nil || argsErr != nil || executable != binary || !ownerArgsMatch(args, binary, state) {
		_ = unix.Close(fd)
		if err != nil {
			return nil, err
		}
		if argsErr != nil {
			return nil, argsErr
		}
		if executable != binary {
			return nil, fmt.Errorf("executable changed to %q", executable)
		}
		return nil, errors.New("process identity changed before pidfd capture")
	}
	return &owner{fd: fd}, nil
}

func ownerPids(binary, state string) []int {
	entries, _ := os.ReadDir("/proc")
	result := make([]int, 0)
	for _, entry := range entries {
		var pid int
		if _, err := fmt.Sscanf(entry.Name(), "%d", &pid); err != nil {
			continue
		}
		args, err := cmdline(pid)
		if err == nil && ownerArgsMatch(args, binary, state) {
			result = append(result, pid)
		}
	}
	sort.Ints(result)
	return result
}

func ownerChild(parent int, binary, state string, timeout time.Duration) (*owner, error) {
	deadline := time.Now().Add(timeout)
	var last string
	for time.Now().Before(deadline) {
		tasks, readErr := filepath.Glob(fmt.Sprintf("/proc/%d/task/*/children", parent))
		last = fmt.Sprintf("tasks=%v read=%v", tasks, readErr)
		for _, task := range tasks {
			children, err := os.ReadFile(task)
			if err != nil {
				continue
			}
			for _, part := range strings.Fields(string(children)) {
				var pid int
				if _, err := fmt.Sscanf(part, "%d", &pid); err != nil {
					continue
				}
				if candidate, err := ownerPidfd(pid, binary, state); err == nil {
					return candidate, nil
				} else {
					last = fmt.Sprintf("pid=%d: %v", pid, err)
				}
			}
		}
		time.Sleep(25 * time.Millisecond)
	}
	return nil, fmt.Errorf("retained owner did not appear for state %s (%s)", state, last)
}

func (o *owner) stop() error {
	if o == nil {
		return nil
	}
	fd := o.fd
	o.fd = -1
	if fd < 0 {
		return nil
	}
	defer unix.Close(fd)
	wait := func(timeout time.Duration) bool {
		poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
		_, err := unix.Poll(poll, int(timeout/time.Millisecond))
		return err == nil && poll[0].Revents != 0
	}
	if wait(0) {
		return nil
	}
	if err := unix.PidfdSendSignal(fd, unix.SIGTERM, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	if wait(10 * time.Second) {
		return nil
	}
	if err := unix.PidfdSendSignal(fd, unix.SIGKILL, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	if !wait(5 * time.Second) {
		return errors.New("fixture owner did not exit after SIGKILL")
	}
	return nil
}

func (o *owner) kill() error {
	if o == nil {
		return nil
	}
	fd := o.fd
	o.fd = -1
	if fd < 0 {
		return nil
	}
	defer unix.Close(fd)
	wait := func(timeout time.Duration) bool {
		poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
		_, err := unix.Poll(poll, int(timeout/time.Millisecond))
		return err == nil && poll[0].Revents != 0
	}
	if wait(0) {
		return nil
	}
	if err := unix.PidfdSendSignal(fd, unix.SIGKILL, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	if !wait(5 * time.Second) {
		return errors.New("fixture owner did not exit after SIGKILL")
	}
	return nil
}

func stopFixtureOwners(binary, state string) error {
	for _, pid := range ownerPids(binary, state) {
		candidate, err := ownerPidfd(pid, binary, state)
		if err != nil {
			continue
		}
		if err := candidate.stop(); err != nil {
			return fmt.Errorf("stop owner %d: %w", pid, err)
		}
	}
	return nil
}

func countThreadWork(state string) error {
	database := filepath.Join(state, "threads.db")
	if _, err := os.Stat(database); err != nil {
		return fmt.Errorf("native launch did not initialize %s: %w", database, err)
	}
	db, err := sql.Open("sqlite3", database)
	if err != nil {
		return fmt.Errorf("open threads database: %w", err)
	}
	defer db.Close()
	for _, table := range []string{"bee_thread_heads", "bee_thread_actions", "bee_thread_attempts"} {
		var count int
		if err := db.QueryRow("SELECT COUNT(*) FROM \"" + table + "\"").Scan(&count); err != nil {
			return fmt.Errorf("count %s: %w", table, err)
		}
		if count != 0 {
			return fmt.Errorf("opening the Agent picker created %d rows in %s", count, table)
		}
	}
	return nil
}

func rawManagedAliasRefusal(binary string) error {
	root, err := os.MkdirTemp("", "bee-native-agent-raw-alias-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		return err
	}
	ui, err := newDesktopWithArguments(binary, project, state, home,
		[]string{"codex", "--dangerously-bypass-profile"})
	if err != nil {
		return err
	}
	defer func() {
		ui.close()
		_ = stopFixtureOwners(binary, state)
	}()
	select {
	case <-ui.wait:
	case <-time.After(5 * time.Second):
		return errors.New("managed alias with raw arguments did not refuse promptly")
	}
	_, _, log := ui.snapshot()
	if !strings.Contains(string(log), "Managed Bee command does not accept raw arguments: codex") {
		return fmt.Errorf("managed raw-argument refusal was not visible:\n%s", string(log))
	}
	if _, err := os.Stat(filepath.Join(state, "threads.db")); err == nil {
		return countThreadWork(state)
	} else if !os.IsNotExist(err) {
		return err
	}
	return nil
}

func defaultPicker(binary string) error {
	root, err := os.MkdirTemp("", "bee-native-agent-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		return err
	}
	ui, err := newDesktop(binary, project, state, home)
	if err != nil {
		return err
	}
	var retained *owner
	defer func() {
		ui.close()
		_ = retained.stop()
		_ = stopFixtureOwners(binary, state)
	}()
	if err := ui.waitFor("Choose a profile", 25*time.Second); err != nil {
		return err
	}
	// The picker shell is visible before its asynchronous catalog reply. Wait
	// for the final shipped row so the assertions below inspect a loaded
	// snapshot rather than racing the honest "Loading profiles…" state.
	if err := ui.waitFor("Muse", 25*time.Second); err != nil {
		return err
	}
	for _, profile := range []string{"Antigravity", "Claude", "Codex", "Grok", "Muse"} {
		latest, _, _ := ui.snapshot()
		if !ui.observed(profile, 0) {
			return fmt.Errorf("picker omitted default profile %q\n%s", profile, latest)
		}
	}
	// Exercise the complete saved-profile form before launching anything.
	// New duplicates the selected reviewed default, so this also proves the
	// form starts from the current title rather than an empty caller payload.
	if err := countThreadWork(state); err != nil {
		return fmt.Errorf("picker created thread work before profile editing: %w", err)
	}
	if err := ui.send("n"); err != nil {
		return err
	}
	if err := ui.waitFor("NEW AGENT PROFILE", 5*time.Second); err != nil {
		return err
	}
	if err := ui.waitFor("Name: Antigravity", 5*time.Second); err != nil {
		return fmt.Errorf("new profile did not start with selected title: %w", err)
	}
	if err := ui.send("\x15Aardvark\tUse saved guidance.\nSecond line."); err != nil {
		return err
	}
	_, before, _ := ui.snapshot()
	if err := ui.send("\x13"); err != nil {
		return err
	}
	if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
		return fmt.Errorf("new profile did not return to picker: %w", err)
	}
	if err := ui.waitForAfter("Aardvark", before, 5*time.Second); err != nil {
		return fmt.Errorf("saved profile did not appear in picker: %w", err)
	}
	if err := countThreadWork(state); err != nil {
		return fmt.Errorf("saving profile created thread work before launch: %w", err)
	}

	// The refreshed list is sorted by title, putting Aardvark first. Edit that
	// selected row and replace both text fields, then prove the committed row.
	if err := ui.send("e"); err != nil {
		return err
	}
	if err := ui.waitFor("EDIT AGENT PROFILE", 5*time.Second); err != nil {
		return err
	}
	if err := ui.waitFor("Name: Aardvark", 5*time.Second); err != nil {
		return fmt.Errorf("edit did not load the saved title: %w", err)
	}
	if err := ui.send("\x15Aardvark Edited\t\x15Edited guidance."); err != nil {
		return err
	}
	_, before, _ = ui.snapshot()
	if err := ui.send("\x13"); err != nil {
		return err
	}
	if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
		return fmt.Errorf("edited profile did not return to picker: %w", err)
	}
	if err := ui.waitForAfter("Aardvark Edited", before, 5*time.Second); err != nil {
		return fmt.Errorf("edited profile did not appear in picker: %w", err)
	}
	if err := countThreadWork(state); err != nil {
		return fmt.Errorf("editing profile created thread work before launch: %w", err)
	}

	// Remove the selected saved row, requiring the form's explicit confirmation,
	// and prove the row disappears after the committed tombstone refresh.
	if err := ui.send("e"); err != nil {
		return err
	}
	if err := ui.waitFor("EDIT AGENT PROFILE", 5*time.Second); err != nil {
		return err
	}
	if err := ui.send("\x04"); err != nil {
		return err
	}
	if err := ui.waitFor("Remove this profile?", 5*time.Second); err != nil {
		return err
	}
	_, before, _ = ui.snapshot()
	if err := ui.send("\r"); err != nil {
		return err
	}
	if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
		return fmt.Errorf("removed profile did not return to picker: %w", err)
	}
	if err := ui.waitAbsent("Aardvark Edited", before, 5*time.Second); err != nil {
		return err
	}
	if err := countThreadWork(state); err != nil {
		return fmt.Errorf("removing profile created thread work before launch: %w", err)
	}
	// Unavailable rows do not launch work. Enter and Refresh may leave
	// identical pixels, so neither operation requires a fresh physical frame.
	if err := ui.send("\r"); err != nil {
		return err
	}
	if err := ui.waitFor("Choose a profile", 5*time.Second); err != nil {
		return err
	}
	retained, err = ownerChild(ui.cmd.Process.Pid, binary, state, 10*time.Second)
	if err != nil {
		return err
	}
	if err := ui.send("r"); err != nil {
		return err
	}
	if err := ui.waitFor("Choose a profile", 5*time.Second); err != nil {
		return err
	}
	_, before, _ = ui.snapshot()
	if err := ui.send("\x1b[24~"); err != nil {
		return err
	}
	// A presenter replacement may reproduce identical pixels. Resize gives
	// the native bridge observable work without relying on an incidental redraw.
	if err := ui.resize(101, 31); err != nil {
		return err
	}
	if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
		return err
	}
	if err := ui.send("\x1b"); err != nil {
		return err
	}
	if err := ui.waitAbsent("Choose a profile", before, 5*time.Second); err != nil {
		return err
	}
	if err := ui.quit(); err != nil {
		return err
	}
	if err := retained.stop(); err != nil {
		return err
	}
	retained = nil
	return countThreadWork(state)
}

// savedProfileLaunch proves that a profile edited through the native picker
// survives admission into a real managed window. The executable is a fixture
// script: it checks the Agy instruction file and then uses the existing MCP
// probe, so this acceptance never contacts a paid provider.
func savedProfileLaunch(binary string) error {
	root, err := os.MkdirTemp("", "bee-native-saved-profile-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	marker, mcpReport := filepath.Join(root, "guidance-proof"), filepath.Join(root, "mcp-report")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		return err
	}
	helper := filepath.Join(filepath.Dir(os.Args[0]), filepath.Base(os.Args[0]))
	if resolved, helperErr := filepath.EvalSymlinks(os.Args[0]); helperErr == nil {
		helper = resolved
	}
	// Keep the child alive beyond placement's 30-second sweep before MCP I/O.
	// A missing PTY supervision reply used to revoke this live binding.
	const guidance = "Saved launch guidance."
	script := "#!/bin/sh\nset -eu\ncase \" $* \" in *\" --effort high \"*) ;; *) exit 1 ;; esac\n" +
		"config_root=\nprevious=\nfor argument in \"$@\"; do if [ \"$previous\" = --add-dir ]; then config_root=$argument; break; fi; previous=$argument; done\n" +
		"[ -n \"$config_root\" ]\nactual=$(cat \"$config_root/.agents/AGENTS.md\")\n[ \"$actual\" = " + shellQuote(guidance) + " ]\nsleep 35\nif ! " +
		shellQuote(helper) + " mcp-probe agy " + shellQuote(mcpReport) + " --subset \"$@\"; then exit 1; fi\nprintf '%s\\n' BEE_SAVED_PROFILE_GUIDANCE\nprintf '%s' \"$actual\" > " +
		shellQuote(marker) + "\nIFS= read -r answer\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "agy"), []byte(script), 0700); err != nil {
		return err
	}
	ui, err := newDesktop(binary, project, state, home)
	if err != nil {
		return err
	}
	defer func() {
		ui.close()
		_ = stopFixtureOwners(binary, state)
	}()
	if err := ui.waitFor("Choose a profile", 25*time.Second); err != nil {
		return err
	}
	if err := ui.send("n"); err != nil {
		return err
	}
	if err := ui.waitFor("NEW AGENT PROFILE", 5*time.Second); err != nil {
		return err
	}
	if err := ui.waitFor("Name: Antigravity", 5*time.Second); err != nil {
		return err
	}
	if err := ui.send("\x15Saved Launch\t\x15" + guidance + "\t\x1b[C\x1b[C\x1b[C\t \t \t \t "); err != nil {
		return err
	}
	_, before, _ := ui.snapshot()
	if err := ui.send("\x13"); err != nil {
		return err
	}
	if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
		return fmt.Errorf("saved launch profile did not return to picker: %w", err)
	}
	if err := ui.waitForAfter("Saved Launch", before, 5*time.Second); err != nil {
		return fmt.Errorf("saved launch profile did not appear in picker: %w", err)
	}
	// The picker refreshes with the first default selected; move to the saved
	// row (after the five built-in profiles) before opening it.
	if err := ui.send("\x1b[B\x1b[B\x1b[B\x1b[B\x1b[B"); err != nil {
		return err
	}
	if err := ui.send("\r"); err != nil {
		return err
	}
	if err := ui.waitFor("BEE_SAVED_PROFILE_GUIDANCE", 65*time.Second); err != nil {
		return fmt.Errorf("saved profile launch did not deliver guidance: %w", err)
	}
	data, err := os.ReadFile(marker)
	if err != nil || string(data) != guidance {
		return fmt.Errorf("saved profile guidance proof = %q, err=%v", string(data), err)
	}
	mcpData, err := os.ReadFile(mcpReport)
	if err != nil {
		return fmt.Errorf("read saved profile MCP report: %w", err)
	}
	var mcpResult mcpProbeReport
	if err := json.Unmarshal(mcpData, &mcpResult); err != nil || mcpResult.Provider != "agy" ||
		mcpResult.InitializeStatus != http.StatusOK || mcpResult.ListStatus != http.StatusOK ||
		mcpResult.ReadStatus != http.StatusOK || mcpResult.WaitStatus != http.StatusOK || mcpResult.MessageStatus != http.StatusOK ||
		!mcpResult.ReadOK || !mcpResult.WaitOK || !mcpResult.MessageRefusedOK || !mcpResult.NoAppendOK ||
		!mcpResult.ReadAnnotationOK || !mcpResult.WaitAnnotationOK || mcpResult.MessageWriteOK ||
		strings.Join(mcpResult.Tools, ",") != "thread_read,thread_wait,workspace" {
		return fmt.Errorf("saved profile MCP report did not prove gateway access: %q", string(mcpData))
	}
	if err := ui.quit(); err != nil {
		return err
	}
	return nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

type recoveryApplication struct {
	ID            string `json:"id"`
	InstanceID    string `json:"instance_id"`
	DefinitionID  string `json:"definition_id"`
	ThreadID      string `json:"thread_id"`
	ResumeState   string `json:"resume_state"`
	RestartPolicy string `json:"restart_policy"`
}

type recoveryWorkspace struct {
	Applications []recoveryApplication `json:"applications"`
}

type recoverySaved struct {
	PreviousAttemptID string `json:"previous_attempt_id"`
	ThreadID          string `json:"thread_id"`
	DefinitionRef     string `json:"definition_ref"`
	OriginRequestID   string `json:"origin_request_id"`
}

type recoveryPlacement struct {
	AttemptID  string
	ActionID   string
	Execution  string
	Cleanup    string
	ExitSource sql.NullString
	PID        sql.NullInt64
	PGID       sql.NullInt64
	StartTicks sql.NullInt64
	BootID     sql.NullString
}

func openRecoveryDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite3", "file:"+path+"?mode=ro")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec("PRAGMA busy_timeout = 2000"); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func readRecoveryWorkspace(state string) (recoveryWorkspace, error) {
	db, err := openRecoveryDB(filepath.Join(state, "workspace.db"))
	if err != nil {
		return recoveryWorkspace{}, err
	}
	defer db.Close()
	var encoded string
	if err := db.QueryRow("SELECT value FROM workspace_state WHERE singleton = 1").Scan(&encoded); err != nil {
		return recoveryWorkspace{}, err
	}
	var snapshot recoveryWorkspace
	if err := json.Unmarshal([]byte(encoded), &snapshot); err != nil {
		return recoveryWorkspace{}, err
	}
	return snapshot, nil
}

func readRecoveryPlacement(state string) ([]recoveryPlacement, error) {
	db, err := openRecoveryDB(filepath.Join(state, "placement.db"))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query(`SELECT attempt_id, action_id, execution_state, cleanup_state,
        exit_source, pid, pgid, start_ticks, boot_id
        FROM bee_placement_attempts ORDER BY created_at, attempt_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []recoveryPlacement
	for rows.Next() {
		var item recoveryPlacement
		if err := rows.Scan(&item.AttemptID, &item.ActionID, &item.Execution, &item.Cleanup,
			&item.ExitSource, &item.PID, &item.PGID, &item.StartTicks, &item.BootID); err != nil {
			return nil, err
		}
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

func recoveryIdentityValid(item recoveryPlacement) bool {
	return item.PID.Valid && item.PGID.Valid && item.StartTicks.Valid && item.BootID.Valid &&
		item.PID.Int64 > 1 && item.PGID.Int64 > 1 && item.StartTicks.Int64 > 0 && item.BootID.String != ""
}

// recoveryIdentityAlive compares the recorded native identity with /proc.
// A PID match by itself is insufficient because Linux can reuse a PID.
func recoveryIdentityAlive(item recoveryPlacement) (bool, error) {
	if !recoveryIdentityValid(item) {
		return false, errors.New("old native attempt has an incomplete process identity")
	}
	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", item.PID.Int64))
	if err != nil {
		if os.IsNotExist(err) || errors.Is(err, unix.ESRCH) {
			return false, nil
		}
		return false, err
	}
	close := bytes.LastIndex(stat, []byte(") "))
	if close < 0 || close+2 >= len(stat) {
		return false, errors.New("native process stat is malformed")
	}
	fields := strings.Fields(string(stat[close+2:]))
	if len(fields) <= 19 {
		return false, errors.New("native process stat omitted start ticks")
	}
	pgid, err := strconv.ParseInt(fields[2], 10, 64)
	if err != nil {
		return false, err
	}
	ticks, err := strconv.ParseInt(fields[19], 10, 64)
	if err != nil {
		return false, err
	}
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return false, err
	}
	return pgid == item.PGID.Int64 && ticks == item.StartTicks.Int64 &&
		strings.TrimSpace(string(boot)) == item.BootID.String, nil
}

func killRecoveryProcess(item recoveryPlacement) error {
	if !recoveryIdentityValid(item) {
		return errors.New("refusing cleanup of native process without a complete identity")
	}
	fd, err := unix.PidfdOpen(int(item.PID.Int64), 0)
	if err != nil {
		if errors.Is(err, unix.ESRCH) {
			return nil
		}
		return err
	}
	defer unix.Close(fd)
	alive, err := recoveryIdentityAlive(item)
	if err != nil || !alive {
		return err
	}
	if err := unix.PidfdSendSignal(fd, unix.SIGKILL, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	_, err = unix.Poll(poll, 5000)
	if err != nil {
		return err
	}
	if poll[0].Revents == 0 {
		return errors.New("identity-proven native process did not exit after cleanup")
	}
	return nil
}

func readRecoveryBinding(state, attemptID string) (string, error) {
	db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return "", err
	}
	defer db.Close()
	var encoded string
	err = db.QueryRow("SELECT checkpoint_json FROM bee_thread_carriers WHERE attempt_id = ? ORDER BY carrier_epoch DESC LIMIT 1", attemptID).Scan(&encoded)
	if err != nil {
		return "", err
	}
	var checkpoint map[string]any
	if err := json.Unmarshal([]byte(encoded), &checkpoint); err != nil {
		return "", err
	}
	binding, ok := checkpoint["gateway_binding"].(string)
	if !ok || binding == "" {
		return "", errors.New("carrier checkpoint has no gateway binding")
	}
	return binding, nil
}

func assertManagedRoute(state, provider string) error {
	workspace, err := readRecoveryWorkspace(state)
	if err != nil {
		return fmt.Errorf("read managed workspace route: %w", err)
	}
	var app recoveryApplication
	var saved recoverySaved
	for _, candidate := range workspace.Applications {
		if candidate.DefinitionID != "bee.harness.window:app" || candidate.ResumeState == "" {
			continue
		}
		var value recoverySaved
		if json.Unmarshal([]byte(candidate.ResumeState), &value) == nil && value.PreviousAttemptID != "" {
			app, saved = candidate, value
			break
		}
	}
	expectedDefinition := "bee.driver." + provider + ":default_window"
	if app.DefinitionID != "bee.harness.window:app" || saved.DefinitionRef != expectedDefinition ||
		saved.ThreadID == "" || saved.PreviousAttemptID == "" || saved.OriginRequestID == "" {
		return fmt.Errorf("managed route identity mismatch: app=%+v checkpoint=%+v, expected definition %s", app, saved, expectedDefinition)
	}
	placements, err := readRecoveryPlacement(state)
	if err != nil {
		return fmt.Errorf("read managed placement route: %w", err)
	}
	var placement recoveryPlacement
	for _, candidate := range placements {
		if candidate.AttemptID == saved.PreviousAttemptID {
			placement = candidate
			break
		}
	}
	if placement.AttemptID == "" || placement.ActionID == "" {
		return errors.New("managed route has no matching placement attempt")
	}
	threads, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return err
	}
	var carrierThread, preparedJSON string
	err = threads.QueryRow("SELECT thread_id FROM bee_thread_carriers WHERE attempt_id = ?", placement.AttemptID).Scan(&carrierThread)
	if err == nil {
		err = threads.QueryRow(`SELECT record_json FROM bee_thread_records
            WHERE thread_id = ? AND action_id = ? AND attempt_id = ? AND kind = 'attempt.prepared'
            ORDER BY sequence DESC LIMIT 1`, saved.ThreadID, placement.ActionID, placement.AttemptID).Scan(&preparedJSON)
	}
	threads.Close()
	if err != nil {
		return fmt.Errorf("read managed carrier route: %w", err)
	}
	if carrierThread != saved.ThreadID {
		return fmt.Errorf("carrier thread %q differs from application thread %q", carrierThread, saved.ThreadID)
	}
	var record struct {
		Body struct {
			BindingRef       string `json:"binding_ref"`
			ProfileID        string `json:"profile_id"`
			PlacementBinding string `json:"placement_binding"`
		} `json:"body"`
	}
	if err := json.Unmarshal([]byte(preparedJSON), &record); err != nil {
		return fmt.Errorf("decode managed prepared record: %w", err)
	}
	expectedBinding := "bee.driver." + provider + ":binding"
	if record.Body.BindingRef != expectedBinding || record.Body.ProfileID != "window" ||
		record.Body.PlacementBinding != "bee.placement.native:binding" {
		return fmt.Errorf("managed prepared route = binding %q, profile %q, placement %q",
			record.Body.BindingRef, record.Body.ProfileID, record.Body.PlacementBinding)
	}
	bindingID, err := readRecoveryBinding(state, placement.AttemptID)
	if err != nil {
		return err
	}
	gateway, err := openRecoveryDB(filepath.Join(state, "gateway.db"))
	if err != nil {
		return err
	}
	var gatewayThread, gatewayAction, gatewayAttempt string
	err = gateway.QueryRow("SELECT thread_id, action_id, attempt_id FROM bee_gateway_bindings WHERE binding_id = ?", bindingID).
		Scan(&gatewayThread, &gatewayAction, &gatewayAttempt)
	gateway.Close()
	if err != nil {
		return fmt.Errorf("read managed gateway route: %w", err)
	}
	if gatewayThread != saved.ThreadID || gatewayAction != placement.ActionID || gatewayAttempt != placement.AttemptID {
		return errors.New("managed MCP gateway does not belong to the application thread and placement")
	}
	return nil
}

func recoveryHookCommitted(state, threadID, sessionID string) (bool, error) {
	db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return false, err
	}
	defer db.Close()
	rows, err := db.Query(`SELECT record_json FROM bee_thread_records
        WHERE thread_id = ? AND kind = 'observation' AND source = 'bee' ORDER BY sequence`, threadID)
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var encoded string
		if err := rows.Scan(&encoded); err != nil {
			return false, err
		}
		var record map[string]any
		if json.Unmarshal([]byte(encoded), &record) != nil {
			continue
		}
		body, ok := record["body"].(map[string]any)
		if !ok {
			continue
		}
		data, ok := body["data"].(map[string]any)
		if !ok || data["event_name"] != "bee.harness.hook" {
			continue
		}
		payloadText, ok := data["payload_json"].(string)
		if !ok {
			continue
		}
		var payload map[string]any
		if json.Unmarshal([]byte(payloadText), &payload) != nil {
			continue
		}
		fields, ok := payload["fields"].(map[string]any)
		if ok && fields["session_id"] == sessionID && fields["tool_use_id"] == "native-recovery-tool" {
			return true, nil
		}
	}
	if err := rows.Err(); err != nil {
		return false, err
	}
	return false, nil
}

func recoveryHookCounts(state, attemptID, bindingID, sessionID string) (map[string]int, error) {
	db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query("SELECT record_json FROM bee_thread_records WHERE kind='observation' AND source='bee' ORDER BY sequence")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	counts := map[string]int{}
	for rows.Next() {
		var encoded string
		if err := rows.Scan(&encoded); err != nil {
			return nil, err
		}
		var record map[string]any
		if json.Unmarshal([]byte(encoded), &record) != nil || record["attempt_id"] != attemptID {
			continue
		}
		body, _ := record["body"].(map[string]any)
		data, _ := body["data"].(map[string]any)
		if data["event_name"] != "bee.harness.hook" {
			continue
		}
		raw, _ := data["payload_json"].(string)
		var payload map[string]any
		if json.Unmarshal([]byte(raw), &payload) != nil || payload["binding_id"] != bindingID {
			continue
		}
		fields, _ := payload["fields"].(map[string]any)
		if fields["session_id"] != sessionID {
			return nil, errors.New("provider hook changed conversation identity")
		}
		event, _ := payload["event"].(string)
		counts[event]++
	}
	return counts, rows.Err()
}

func recoveryThreadFacts(state, threadID, actionID string) (int, int, error) {
	db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
	if err != nil {
		return 0, 0, err
	}
	defer db.Close()
	var turns, successes int
	if err := db.QueryRow("SELECT COUNT(*) FROM bee_thread_records WHERE thread_id = ? AND kind = 'turn.request'", threadID).Scan(&turns); err != nil {
		return 0, 0, err
	}
	if err := db.QueryRow("SELECT COUNT(*) FROM bee_thread_settlements WHERE thread_id = ? AND action_id = ? AND outcome = 'succeeded'", threadID, actionID).Scan(&successes); err != nil {
		return 0, 0, err
	}
	return turns, successes, nil
}

func waitRecoveryWorkspace(state string, predicate func(recoveryWorkspace) (recoveryApplication, recoverySaved, bool), timeout time.Duration) (recoveryApplication, recoverySaved, error) {
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		snapshot, err := readRecoveryWorkspace(state)
		if err == nil {
			if app, saved, ok := predicate(snapshot); ok {
				return app, saved, nil
			}
		} else {
			last = err
		}
		time.Sleep(100 * time.Millisecond)
	}
	if last != nil {
		return recoveryApplication{}, recoverySaved{}, fmt.Errorf("workspace checkpoint: %w", last)
	}
	return recoveryApplication{}, recoverySaved{}, errors.New("workspace checkpoint did not reach the expected state")
}

func recoveryArgs(path string) ([]string, string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", err
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) < 3 || lines[0] == "" || lines[1] == "" {
		return nil, "", fmt.Errorf("malformed launch report %q", string(data))
	}
	return lines[2:], lines[1], nil
}

func hasRecoveryResume(args []string, expected string) bool {
	for index, arg := range args {
		if arg == "-r" && index+1 < len(args) && args[index+1] == expected {
			return true
		}
	}
	return false
}

// nativeAgentRecovery proves a graceful cold restart through the public
// picker. The first child writes an acknowledged PreToolUse hook and a HOME
// marker, the retained owner is stopped via pidfd, and a second Bee boots the
// same state directory and launches the restored application.
func nativeAgentRecovery(binary string) error {
	return nativeAgentRecoveryMode(binary, false)
}

func nativeAgentRecoveryCrash(binary string) error {
	return nativeAgentRecoveryMode(binary, true)
}

func nativeAgentRecoveryMode(binary string, crash bool) (result error) {
	root, err := os.MkdirTemp("", "bee-native-agent-recovery-")
	if err != nil {
		return err
	}
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	for _, dir := range []string{filepath.Join(project, "bin"), state, home} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			return err
		}
	}
	helper, err := filepath.Abs(os.Args[0])
	if err != nil {
		return err
	}
	firstReport, secondReport := filepath.Join(root, "first-launch"), filepath.Join(root, "second-launch")
	script := "#!/bin/sh\nset -eu\nphase=first\nif [ -f \"$HOME/bee-session-proof\" ]; then phase=second; fi\nif [ \"$phase\" = second ]; then [ \"$(cat \"$HOME/bee-session-proof\")\" = retained ]; [ -z \"${CLAUDE_CONFIG_DIR-}\" ]; fi\nreport=" + shellQuote(firstReport) + "\nif [ \"$phase\" = second ]; then report=" + shellQuote(secondReport) + "; fi\nprintf '%s\\n%s\\n' \"$PWD\" \"$HOME\" > \"$report\"\nprintf '%s\\n' \"$@\" >> \"$report\"\nif [ \"$phase\" = first ]; then " + shellQuote(helper) + " hook-probe \"$@\"; fi\nprintf 'BEE_RECOVERY_AGENT_READY_%s\\n' \"$phase\"\nprintf retained > \"$HOME/bee-session-proof\"\nIFS= read -r answer\n"
	if err := os.WriteFile(filepath.Join(project, "bin", "claude"), []byte(script), 0700); err != nil {
		return err
	}
	firstBinary := binary
	if previous := os.Getenv("BEE_RECOVERY_PREVIOUS_BINARY"); previous != "" {
		firstBinary, err = filepath.Abs(previous)
		if err != nil {
			return err
		}
	}
	var first *desktop
	var second *desktop
	var retained *owner
	var oldAttemptID string
	crashOutcome := ""
	defer func() {
		if retained != nil {
			_ = retained.stop()
		}
		if first != nil {
			first.close()
		}
		if second != nil {
			second.close()
		}
		_ = stopFixtureOwners(binary, state)
		if firstBinary != binary {
			_ = stopFixtureOwners(firstBinary, state)
		}
		if crash {
			if rows, readErr := readRecoveryPlacement(state); readErr == nil {
				for _, item := range rows {
					if item.AttemptID == oldAttemptID {
						_ = killRecoveryProcess(item)
					}
				}
			}
		}
		if result != nil {
			diagnostic := filepath.Join(root, "recovery-diagnosis.txt")
			_ = os.WriteFile(diagnostic, []byte(result.Error()), 0600)
			fmt.Fprintf(os.Stderr, "native Agent recovery fixture retained at %s: %v\\n", root, result)
		} else {
			_ = os.RemoveAll(root)
		}
	}()
	first, err = newDesktop(firstBinary, project, state, home)
	if err != nil {
		return err
	}
	if err = first.waitFor("Claude", 25*time.Second); err != nil {
		return err
	}
	if err = first.send("\x1b[B"); err != nil {
		return err
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	for _, detail := range []string{"Configured folder", "No instructions", "7 tools configured"} {
		if err = first.waitFor(detail, 5*time.Second); err != nil {
			return fmt.Errorf("recovery profile summary: %w", err)
		}
	}
	if err = first.send("\r"); err != nil {
		return err
	}
	if err = first.waitFor("BEE_RECOVERY_AGENT_READY_first", 25*time.Second); err != nil {
		return err
	}
	args, childHome, err := recoveryArgs(firstReport)
	if err != nil {
		return err
	}
	if hasRecoveryResume(args, "native-recovery-session") {
		return errors.New("first Claude launch unexpectedly carried a resume reference")
	}
	if childHome == "" {
		return errors.New("first recovery child has no HOME")
	}
	app, saved, err := waitRecoveryWorkspace(state, func(snapshot recoveryWorkspace) (recoveryApplication, recoverySaved, bool) {
		for _, candidate := range snapshot.Applications {
			var decoded recoverySaved
			if candidate.DefinitionID != "bee.harness.window:app" || candidate.ResumeState == "" || json.Unmarshal([]byte(candidate.ResumeState), &decoded) != nil {
				continue
			}
			if decoded.PreviousAttemptID != "" && decoded.ThreadID != "" {
				return candidate, decoded, true
			}
		}
		return recoveryApplication{}, recoverySaved{}, false
	}, 30*time.Second)
	if err != nil {
		return err
	}
	if saved.PreviousAttemptID == "" || saved.ThreadID == "" {
		return errors.New("checkpoint omitted native attempt identity")
	}
	hookDeadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(hookDeadline) {
		committed, hookErr := recoveryHookCommitted(state, saved.ThreadID, "native-recovery-session")
		if hookErr == nil && committed {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	committed, err := recoveryHookCommitted(state, saved.ThreadID, "native-recovery-session")
	if err != nil || !committed {
		return fmt.Errorf("native recovery PreToolUse was not committed: %v", err)
	}
	placements, err := readRecoveryPlacement(state)
	if err != nil {
		return err
	}
	var old recoveryPlacement
	for _, candidate := range placements {
		if candidate.AttemptID == saved.PreviousAttemptID {
			old = candidate
		}
	}
	if old.AttemptID == "" {
		return errors.New("checkpoint attempt is absent from placement state")
	}
	oldAttemptID = old.AttemptID
	turns, successes, err := recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil {
		return err
	}
	if turns != 0 || successes != 0 {
		return fmt.Errorf("fixture invented turn facts: turns=%d successes=%d", turns, successes)
	}
	oldBinding, err := readRecoveryBinding(state, old.AttemptID)
	if err != nil {
		return err
	}
	retained, err = ownerChild(first.cmd.Process.Pid, firstBinary, state, 10*time.Second)
	if err != nil {
		return err
	}
	if !recoveryIdentityValid(old) {
		return errors.New("old native attempt has no complete identity before owner restart")
	}
	if crash {
		if err = retained.kill(); err != nil {
			return fmt.Errorf("kill retained owner: %w", err)
		}
	} else if err = retained.stop(); err != nil {
		return fmt.Errorf("stop retained owner: %w", err)
	}
	retained = nil
	first.close()
	if crash {
		afterKill, readErr := readRecoveryPlacement(state)
		if readErr != nil {
			return fmt.Errorf("inspect native identity after owner SIGKILL: %w", readErr)
		}
		var observed recoveryPlacement
		for _, item := range afterKill {
			if item.AttemptID == old.AttemptID {
				observed = item
			}
		}
		if !recoveryIdentityValid(observed) || observed.PID != old.PID || observed.PGID != old.PGID ||
			observed.StartTicks != old.StartTicks || observed.BootID != old.BootID {
			return errors.New("native identity changed while inspecting the SIGKILL outcome")
		}
		alive, identityErr := recoveryIdentityAlive(observed)
		if identityErr != nil {
			return fmt.Errorf("inspect native identity after owner SIGKILL: %w", identityErr)
		}
		fmt.Fprintf(os.Stderr, "native Agent process alive after owner SIGKILL: %t\n", alive)
	}
	// The current profile may inherit a machine-level configuration override,
	// but an older private session must stay in the configuration root where
	// its provider recorded the conversation.
	var secondEnvironment []string
	if firstBinary != binary {
		secondConfig := filepath.Join(root, "new-machine-claude-config")
		if err = os.MkdirAll(secondConfig, 0700); err != nil {
			return err
		}
		secondEnvironment = []string{"CLAUDE_CONFIG_DIR=" + secondConfig}
	}
	second, err = newDesktopWithArguments(binary, project, state, home, nil, secondEnvironment...)
	if err != nil {
		return err
	}
	if firstBinary != binary {
		if err = second.waitFor("Review Agent changes", 30*time.Second); err != nil {
			return err
		}
		if _, reportErr := os.Stat(secondReport); !os.IsNotExist(reportErr) {
			return errors.New("changed-plan review launched the harness before confirmation")
		}
		rows, readErr := readRecoveryPlacement(state)
		if readErr != nil {
			return readErr
		}
		if len(rows) != 1 || rows[0].AttemptID != old.AttemptID {
			return errors.New("changed-plan review created a replacement attempt before confirmation")
		}
		if err = second.send("\r"); err != nil {
			return err
		}
	}
	if crash {
		deadline := time.Now().Add(30 * time.Second)
		ready, refused := false, false
		for time.Now().Before(deadline) {
			ready = second.observed("BEE_RECOVERY_AGENT_READY_second", 0)
			refused = second.observed("Recovery admission refused", 0)
			if ready || refused {
				break
			}
			select {
			case <-second.done:
				return errors.New("restarted desktop exited before Agent recovery")
			default:
			}
			time.Sleep(100 * time.Millisecond)
		}
		if refused && !ready {
			rows, readErr := readRecoveryPlacement(state)
			if readErr != nil {
				return fmt.Errorf("read refusal placement state: %w", readErr)
			}
			if len(rows) != 1 || rows[0].AttemptID != old.AttemptID {
				return fmt.Errorf("refused recovery created another placement attempt: %d rows", len(rows))
			}
			alive, identityErr := recoveryIdentityAlive(rows[0])
			if identityErr != nil || !alive {
				return fmt.Errorf("recovery refused without a live old native process: %v", identityErr)
			}
			crashOutcome = "refused while the old native process remained alive"
			fmt.Fprintln(os.Stderr, "native Agent crash recovery outcome: "+crashOutcome)
			return errors.New("recovery safely refused a live prior process but did not restore the Agent")
		}
		if !ready {
			return errors.New("SIGKILL recovery neither restored nor reported an exit-unproven refusal")
		}
	}
	if err = second.waitFor("BEE_RECOVERY_AGENT_READY_second", 45*time.Second); err != nil {
		return err
	}
	secondArgs, secondHome, err := recoveryArgs(secondReport)
	if err != nil {
		return err
	}
	if secondHome != childHome {
		return fmt.Errorf("restored HOME changed from %q to %q", childHome, secondHome)
	}
	if !hasRecoveryResume(secondArgs, "native-recovery-session") {
		return errors.New("restored Claude launch omitted its expected resume reference")
	}
	marker, err := os.ReadFile(filepath.Join(secondHome, "bee-session-proof"))
	if err != nil || string(marker) != "retained" {
		return fmt.Errorf("restored HOME sentinel = %q, err=%v", string(marker), err)
	}
	newApp, newSaved, err := waitRecoveryWorkspace(state, func(snapshot recoveryWorkspace) (recoveryApplication, recoverySaved, bool) {
		for _, candidate := range snapshot.Applications {
			var decoded recoverySaved
			if candidate.ID != app.ID || candidate.InstanceID != app.InstanceID || candidate.ResumeState == "" || json.Unmarshal([]byte(candidate.ResumeState), &decoded) != nil {
				continue
			}
			if decoded.PreviousAttemptID != "" && decoded.PreviousAttemptID != old.AttemptID {
				return candidate, decoded, true
			}
		}
		return recoveryApplication{}, recoverySaved{}, false
	}, 30*time.Second)
	if err != nil {
		return err
	}
	if newApp.ID != app.ID || newApp.InstanceID != app.InstanceID || newSaved.ThreadID != saved.ThreadID {
		return errors.New("restored application identity or thread changed")
	}
	newRows, err := readRecoveryPlacement(state)
	if err != nil {
		return err
	}
	if len(newRows) != 2 {
		return fmt.Errorf("expected one old and one new placement attempt, got %d", len(newRows))
	}
	var fresh recoveryPlacement
	var retired recoveryPlacement
	for _, item := range newRows {
		if item.AttemptID == newSaved.PreviousAttemptID {
			fresh = item
		}
		if item.AttemptID == old.AttemptID {
			retired = item
		}
	}
	if retired.Execution != "exited" || retired.Cleanup != "complete" {
		return fmt.Errorf("old native attempt was not reconciled after restart: execution=%s cleanup=%s", retired.Execution, retired.Cleanup)
	}
	if fresh.AttemptID == "" || fresh.ActionID != old.ActionID || fresh.AttemptID == old.AttemptID {
		return errors.New("restored application did not create a fresh attempt")
	}
	newBinding, err := readRecoveryBinding(state, fresh.AttemptID)
	if err != nil {
		return err
	}
	if newBinding == oldBinding {
		return errors.New("restored attempt reused the old gateway binding")
	}
	turns, successes, err = recoveryThreadFacts(state, saved.ThreadID, old.ActionID)
	if err != nil {
		return err
	}
	if turns != 0 || successes != 0 {
		return fmt.Errorf("recovery invented turn facts: turns=%d successes=%d", turns, successes)
	}
	if crash {
		crashOutcome = "continued after owner SIGKILL because the old native process was gone"
		fmt.Fprintln(os.Stderr, "native Agent crash recovery outcome: "+crashOutcome)
	}
	return nil
}

type mcpReply struct {
	JSONRPC string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result"`
	Error   json.RawMessage `json:"error"`
}

type mcpProbeReport struct {
	Provider         string   `json:"provider"`
	InitializeStatus int      `json:"initialize_status"`
	ListStatus       int      `json:"list_status"`
	ReadStatus       int      `json:"read_status"`
	WaitStatus       int      `json:"wait_status"`
	MessageStatus    int      `json:"message_status"`
	Tools            []string `json:"tools"`
	ReadOK           bool     `json:"read_ok"`
	WaitOK           bool     `json:"wait_ok"`
	MessageOK        bool     `json:"message_ok"`
	MessageReplayOK  bool     `json:"message_replay_ok"`
	MessageRefusedOK bool     `json:"message_refused_ok"`
	NoAppendOK       bool     `json:"no_append_ok"`
	ReadAnnotationOK bool     `json:"read_annotation_ok"`
	WaitAnnotationOK bool     `json:"wait_annotation_ok"`
	MessageWriteOK   bool     `json:"message_write_annotation_ok"`
}

// mcpProbeConfig follows the provider credential syntax. Agy uses literal
// headers; Claude and Codex resolve their declared environment references.
// Credential bytes are never written to reports or diagnostics.
func mcpProbeConfig(provider string, args []string) (string, string, bool) {
	if provider == "codex" {
		for index, arg := range args {
			if (arg != "-c" && arg != "--config") || index+1 >= len(args) {
				continue
			}
			const prefix = "mcp_servers.bee={url="
			value := args[index+1]
			if !strings.HasPrefix(value, prefix) {
				continue
			}
			parts := strings.TrimPrefix(value, prefix)
			urlValue, tokenValue, found := strings.Cut(parts, ",bearer_token_env_var=")
			if !found || !strings.HasSuffix(tokenValue, "}") {
				return "", "", false
			}
			endpoint, endpointErr := strconv.Unquote(urlValue)
			tokenName, tokenErr := strconv.Unquote(strings.TrimSuffix(tokenValue, "}"))
			if endpointErr != nil || tokenErr != nil || endpoint == "" || tokenName == "" {
				return "", "", false
			}
			token := os.Getenv(tokenName)
			return endpoint, token, token != ""
		}
		return "", "", false
	}
	if provider == "agy" {
		root, ok := optionValue(args, "--add-dir")
		if !ok {
			return "", "", false
		}
		config, err := os.ReadFile(filepath.Join(root, ".agents", "mcp_config.json"))
		if err != nil {
			return "", "", false
		}
		args = []string{"--mcp-config", string(config)}
	}
	if provider == "claude" || provider == "agy" {
		for index, arg := range args {
			if arg != "--mcp-config" || index+1 >= len(args) {
				continue
			}
			var document struct {
				Servers map[string]struct {
					URL       string            `json:"url"`
					ServerURL string            `json:"serverUrl"`
					Headers   map[string]string `json:"headers"`
				} `json:"mcpServers"`
			}
			if json.Unmarshal([]byte(args[index+1]), &document) != nil {
				return "", "", false
			}
			server, ok := document.Servers["bee"]
			if provider == "agy" {
				server.URL = server.ServerURL
			}
			if !ok || server.URL == "" {
				return "", "", false
			}
			authorization := server.Headers["Authorization"]
			if provider == "agy" {
				if !strings.HasPrefix(authorization, "Bearer ") {
					return "", "", false
				}
				token := strings.TrimPrefix(authorization, "Bearer ")
				return server.URL, token, token != ""
			}
			const prefix, suffix = "Bearer ${", "}"
			if !strings.HasPrefix(authorization, prefix) || !strings.HasSuffix(authorization, suffix) {
				return "", "", false
			}
			name := strings.TrimSuffix(strings.TrimPrefix(authorization, prefix), suffix)
			if name == "" || strings.ContainsAny(name, "=\x00\r\n") {
				return "", "", false
			}
			return server.URL, os.Getenv(name), os.Getenv(name) != ""
		}
		return "", "", false
	}
	if provider != "codex" && provider != "grok" {
		return "", "", false
	}
	config, err := os.ReadFile(filepath.Join(os.Getenv("HOME"), "."+provider, "config.toml"))
	if err != nil {
		return "", "", false
	}
	var url, tokenName string
	inBeeServer := false
	inBeeHeaders := false
	for _, line := range strings.Split(string(config), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			inBeeServer = line == "[mcp_servers.bee]"
			inBeeHeaders = line == "[mcp_servers.bee.headers]"
			continue
		}
		if value, ok := tomlStringAssignment(line, "url"); inBeeServer && ok {
			url = value
		}
		if value, ok := tomlStringAssignment(line, "bearer_token_env_var"); inBeeServer && ok {
			tokenName = value
		}
		if value, ok := tomlStringAssignment(line, "Authorization"); provider == "grok" && inBeeHeaders && ok &&
			strings.HasPrefix(value, "Bearer ${") && strings.HasSuffix(value, "}") {
			tokenName = strings.TrimSuffix(strings.TrimPrefix(value, "Bearer ${"), "}")
		}
	}
	return url, os.Getenv(tokenName), url != "" && os.Getenv(tokenName) != ""
}

// Pelletier's canonical encoder may choose TOML literal strings. This probe
// reads only exact scalar assignments in the already-selected Bee table.
func tomlStringAssignment(line, key string) (string, bool) {
	prefix := key + " ="
	if !strings.HasPrefix(line, prefix) {
		return "", false
	}
	raw := strings.TrimSpace(line[len(prefix):])
	if len(raw) < 2 {
		return "", false
	}
	if raw[0] == '\'' && raw[len(raw)-1] == '\'' {
		value := raw[1 : len(raw)-1]
		return value, !strings.Contains(value, "'")
	}
	if raw[0] != '"' || raw[len(raw)-1] != '"' {
		return "", false
	}
	value, err := strconv.Unquote(raw)
	return value, err == nil
}

func optionValue(args []string, name string) (string, bool) {
	for index, arg := range args {
		if arg == name && index+1 < len(args) && args[index+1] != "" {
			return args[index+1], true
		}
	}
	return "", false
}

func mcpProbeRequest(client *http.Client, url, token, method string, params map[string]any, id int) (int, mcpReply, bool) {
	payload, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	if err != nil {
		return 0, mcpReply{}, false
	}
	request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return 0, mcpReply{}, false
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return 0, mcpReply{}, false
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1024*1024))
	if err != nil {
		return response.StatusCode, mcpReply{}, false
	}
	var reply mcpReply
	if json.Unmarshal(body, &reply) != nil || reply.JSONRPC != "2.0" {
		return response.StatusCode, mcpReply{}, false
	}
	return response.StatusCode, reply, true
}

func mcpProbeReportFile(path string, report mcpProbeReport) {
	data, err := json.Marshal(report)
	if err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0600)
}

func runMCPProbe(provider, reportPath string, args []string) int {
	report := mcpProbeReport{Provider: provider, Tools: []string{}}
	defer func() { mcpProbeReportFile(reportPath, report) }()
	url, token, ok := mcpProbeConfig(provider, args)
	if !ok || token == "" {
		return 1
	}
	parsed, err := http.NewRequest(http.MethodPost, url, nil)
	if err != nil || parsed.URL.Scheme != "http" || parsed.URL.Host == "" ||
		(parsed.URL.Hostname() != "127.0.0.1" && parsed.URL.Hostname() != "localhost") ||
		!strings.HasPrefix(parsed.URL.Path, "/mcp/") {
		return 1
	}
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DisableKeepAlives: true},
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	var initReply mcpReply
	report.InitializeStatus, initReply, ok = mcpProbeRequest(client, url, token, "initialize", map[string]any{
		"protocolVersion": "2025-06-18", "capabilities": map[string]any{}, "clientInfo": map[string]any{"name": "bee-native-agent", "version": "0"},
	}, 1)
	_ = initReply
	if !ok || report.InitializeStatus != http.StatusOK {
		return 1
	}
	var listReply mcpReply
	report.ListStatus, listReply, ok = mcpProbeRequest(client, url, token, "tools/list", map[string]any{}, 2)
	if !ok || report.ListStatus != http.StatusOK {
		return 1
	}
	var listed struct {
		Tools []struct {
			Name        string `json:"name"`
			Annotations struct {
				ReadOnlyHint *bool `json:"readOnlyHint"`
			} `json:"annotations"`
		} `json:"tools"`
	}
	subset := false
	for _, arg := range args {
		if arg == "--subset" {
			subset = true
			break
		}
	}
	// The endpoint always appends the two protocol tools that carry no
	// annotation. They are not part of the launch policy's admitted ceiling, so
	// probe them separately and assert the exact admitted policy list below.
	expected := []string{"thread_read", "thread_wait", "thread_message", "workspace", "delivery", "docs", "components"}
	if subset {
		// The saved-profile form starts from the reviewed default and toggles
		// components, delivery, docs and thread_message off.
		expected = []string{"thread_read", "thread_wait", "workspace"}
	}
	if json.Unmarshal(listReply.Result, &listed) != nil {
		return 1
	}
	seen := map[string]bool{}
	for _, tool := range listed.Tools {
		if tool.Name == "" {
			return 1
		}
		if tool.Name == "session" || tool.Name == "call_tool" {
			if tool.Annotations.ReadOnlyHint != nil {
				return 1
			}
			continue
		}
		if tool.Annotations.ReadOnlyHint == nil {
			return 1
		}
		switch tool.Name {
		case "thread_read":
			report.ReadAnnotationOK = *tool.Annotations.ReadOnlyHint
		case "thread_wait":
			report.WaitAnnotationOK = *tool.Annotations.ReadOnlyHint
		case "thread_message":
			report.MessageWriteOK = !*tool.Annotations.ReadOnlyHint
		case "workspace":
			if *tool.Annotations.ReadOnlyHint {
				return 1
			}
		case "delivery":
			if !*tool.Annotations.ReadOnlyHint {
				return 1
			}
		case "docs":
			if !*tool.Annotations.ReadOnlyHint {
				return 1
			}
		case "components":
			if !*tool.Annotations.ReadOnlyHint {
				return 1
			}
		default:
			return 1
		}
		seen[tool.Name] = true
		report.Tools = append(report.Tools, tool.Name)
	}
	if len(report.Tools) != len(expected) {
		return 1
	}
	for _, name := range expected {
		if !seen[name] {
			return 1
		}
	}
	sort.Strings(report.Tools)
	if subset {
		if strings.Join(report.Tools, ",") != "thread_read,thread_wait,workspace" ||
			!report.ReadAnnotationOK || !report.WaitAnnotationOK || report.MessageWriteOK {
			return 1
		}
		readScanned := func(id int) (int, bool) {
			status, reply, requestOK := mcpProbeRequest(client, url, token, "tools/call", map[string]any{
				"name": "thread_read", "arguments": map[string]any{"cursor": 0},
			}, id)
			report.ReadStatus = status
			if !requestOK || status != http.StatusOK {
				return 0, false
			}
			var result struct {
				Content []struct {
					Text string `json:"text"`
				} `json:"content"`
				IsError bool `json:"isError"`
			}
			if json.Unmarshal(reply.Result, &result) != nil || len(result.Content) != 1 || result.IsError {
				return 0, false
			}
			var value struct {
				OK    bool `json:"ok"`
				Value struct {
					ScannedThrough *int  `json:"scanned_through"`
					HasMore        *bool `json:"has_more"`
				} `json:"value"`
			}
			if json.Unmarshal([]byte(result.Content[0].Text), &value) != nil || !value.OK {
				return 0, false
			}
			if value.Value.ScannedThrough == nil || value.Value.HasMore == nil || *value.Value.HasMore {
				return 0, false
			}
			return *value.Value.ScannedThrough, true
		}
		initialScanned, readOK := readScanned(3)
		if !readOK {
			return 1
		}
		report.ReadOK = true
		messageArguments := map[string]any{
			"idempotency_key": "native-mcp-message-subset",
			"message_id":      "native-mcp-message-subset",
			"message_kind":    "notification",
			"recipient_ids":   []string{},
			"content":         map[string]any{"text": "refused native authenticated message"},
		}
		var messageReply mcpReply
		report.MessageStatus, messageReply, ok = mcpProbeRequest(client, url, token, "tools/call", map[string]any{
			"name": "thread_message", "arguments": messageArguments,
		}, 4)
		if !ok || report.MessageStatus != http.StatusOK {
			return 1
		}
		var messageError struct {
			Code int `json:"code"`
		}
		if json.Unmarshal(messageReply.Error, &messageError) != nil || messageError.Code != -32602 {
			return 1
		}
		report.MessageRefusedOK = true
		// Re-read the initial cursor and compare its durable boundary. The
		// refused write must not append a record.
		afterScanned, readOK := readScanned(5)
		if !readOK || afterScanned != initialScanned {
			return 1
		}
		report.NoAppendOK = true
		var waitReply mcpReply
		report.WaitStatus, waitReply, ok = mcpProbeRequest(client, url, token, "tools/call", map[string]any{
			"name": "thread_wait", "arguments": map[string]any{"after_sequence": afterScanned, "wait_ms": 0},
		}, 6)
		if !ok || report.WaitStatus != http.StatusOK {
			return 1
		}
		var waitResult struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
			IsError bool `json:"isError"`
		}
		if json.Unmarshal(waitReply.Result, &waitResult) != nil || len(waitResult.Content) != 1 || waitResult.IsError {
			return 1
		}
		var waitValue struct {
			OK bool `json:"ok"`
		}
		if json.Unmarshal([]byte(waitResult.Content[0].Text), &waitValue) != nil || !waitValue.OK {
			return 1
		}
		report.WaitOK = true
		return 0
	}
	if strings.Join(report.Tools, ",") != "components,delivery,docs,thread_message,thread_read,thread_wait,workspace" ||
		!report.ReadAnnotationOK || !report.WaitAnnotationOK || !report.MessageWriteOK {
		return 1
	}
	var readReply mcpReply
	report.ReadStatus, readReply, ok = mcpProbeRequest(client, url, token, "tools/call", map[string]any{
		"name": "thread_read", "arguments": map[string]any{"cursor": 0},
	}, 3)
	if !ok || report.ReadStatus != http.StatusOK {
		return 1
	}
	var readResult struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if json.Unmarshal(readReply.Result, &readResult) != nil || len(readResult.Content) != 1 || readResult.IsError {
		return 1
	}
	var readValue struct {
		OK    bool `json:"ok"`
		Value struct {
			ScannedThrough int `json:"scanned_through"`
		} `json:"value"`
	}
	if json.Unmarshal([]byte(readResult.Content[0].Text), &readValue) != nil || !readValue.OK {
		return 1
	}
	report.ReadOK = true
	messageArguments := map[string]any{
		"idempotency_key": "native-mcp-message-" + provider,
		"message_id":      "native-mcp-message-" + provider,
		"message_kind":    "notification",
		"recipient_ids":   []string{},
		"content":         map[string]any{"text": "native authenticated message"},
	}
	var messageReply mcpReply
	report.MessageStatus, messageReply, ok = mcpProbeRequest(client, url, token, "tools/call", map[string]any{
		"name": "thread_message", "arguments": messageArguments,
	}, 4)
	if !ok || report.MessageStatus != http.StatusOK {
		return 1
	}
	var messageResult struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if json.Unmarshal(messageReply.Result, &messageResult) != nil || len(messageResult.Content) != 1 || messageResult.IsError {
		return 1
	}
	var messageValue struct {
		OK       bool `json:"ok"`
		Replayed bool `json:"replayed"`
		Value    struct {
			RecordID string `json:"record_id"`
			Sequence int    `json:"sequence"`
		} `json:"value"`
	}
	if json.Unmarshal([]byte(messageResult.Content[0].Text), &messageValue) != nil || !messageValue.OK || messageValue.Replayed ||
		messageValue.Value.RecordID == "" || messageValue.Value.Sequence <= 0 {
		return 1
	}
	report.MessageOK = true
	var replayMessageReply mcpReply
	replayStatus, replayMessageReply, ok := mcpProbeRequest(client, url, token, "tools/call", map[string]any{
		"name": "thread_message", "arguments": messageArguments,
	}, 5)
	if !ok || replayStatus != http.StatusOK {
		return 1
	}
	var replayMessageResult struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if json.Unmarshal(replayMessageReply.Result, &replayMessageResult) != nil || len(replayMessageResult.Content) != 1 || replayMessageResult.IsError {
		return 1
	}
	var replayMessageValue struct {
		OK       bool `json:"ok"`
		Replayed bool `json:"replayed"`
		Value    struct {
			RecordID string `json:"record_id"`
			Sequence int    `json:"sequence"`
		} `json:"value"`
	}
	if json.Unmarshal([]byte(replayMessageResult.Content[0].Text), &replayMessageValue) != nil || !replayMessageValue.OK || !replayMessageValue.Replayed ||
		replayMessageValue.Value.RecordID != messageValue.Value.RecordID || replayMessageValue.Value.Sequence != messageValue.Value.Sequence {
		return 1
	}
	report.MessageReplayOK = true
	var waitReply mcpReply
	report.WaitStatus, waitReply, ok = mcpProbeRequest(client, url, token, "tools/call", map[string]any{
		"name": "thread_wait", "arguments": map[string]any{"after_sequence": readValue.Value.ScannedThrough, "wait_ms": 0},
	}, 6)
	if !ok || report.WaitStatus != http.StatusOK {
		return 1
	}
	var waitResult struct {
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if json.Unmarshal(waitReply.Result, &waitResult) != nil || len(waitResult.Content) != 1 || waitResult.IsError {
		return 1
	}
	var waitValue struct {
		OK bool `json:"ok"`
	}
	if json.Unmarshal([]byte(waitResult.Content[0].Text), &waitValue) != nil || !waitValue.OK {
		return 1
	}
	report.WaitOK = true
	return 0
}

// runAgyHookProbe executes the delivered command, exactly as Agy's command hook
// does. It does not substitute a direct HTTP client for Bee's native helper.
func runCommandHookProbe(provider, event string, args []string) int {
	path := ""
	if provider == "agy" {
		root, ok := optionValue(args, "--add-dir")
		if !ok {
			return 1
		}
		path = filepath.Join(root, ".agents", "hooks.json")
	}
	if provider == "grok" {
		path = filepath.Join(os.Getenv("HOME"), ".grok", "hooks", "bee.json")
	} else if provider != "agy" {
		return 1
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return 1
	}
	type handler struct {
		Type    string `json:"type"`
		Command string `json:"command"`
	}
	type entry struct {
		Type    string    `json:"type"`
		Command string    `json:"command"`
		Hooks   []handler `json:"hooks"`
	}
	var config struct {
		Bee   map[string][]entry `json:"bee"`
		Hooks map[string][]entry `json:"hooks"`
	}
	if json.Unmarshal(data, &config) != nil {
		return 1
	}
	if provider == "grok" {
		config.Bee = config.Hooks
	}
	if len(config.Bee[event]) != 1 {
		return 1
	}
	selected := config.Bee[event][0]
	command := selected.Command
	if event == "PreToolUse" || provider == "grok" {
		if len(selected.Hooks) != 1 || selected.Hooks[0].Type != "command" {
			return 1
		}
		command = selected.Hooks[0].Command
	} else if event != "Stop" || selected.Type != "command" || len(selected.Hooks) != 0 {
		return 1
	}
	if command == "" {
		return 1
	}
	payload := map[string]any{"conversationId": "native-agy-hook-session", "transcriptPath": "/private/hook-transcript"}
	if event == "PreToolUse" {
		payload["toolCall"] = map[string]any{"name": "view_file", "args": map[string]any{"private": "BEE_PRIVATE_HOOK_CONTENT"}}
		payload["stepIdx"] = 12
	} else {
		payload["fullyIdle"] = true
		payload["executionNum"] = 1
	}
	if provider == "grok" {
		payload = map[string]any{"sessionId": "native-grok-hook-session", "session_id": "native-grok-hook-session", "promptId": "prompt-1", "permissionMode": "default", "permission_mode": "default"}
		if event == "PreToolUse" {
			payload["toolUseId"] = "tool-1"
			payload["toolName"] = "run_terminal_command"
			payload["toolInput"] = map[string]any{"command": "BEE_PRIVATE_HOOK_CONTENT"}
		}
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	child := exec.CommandContext(ctx, "/bin/sh", "-c", command)
	child.Stdin = bytes.NewReader(body)
	var stdout bytes.Buffer
	child.Stdout = &stdout
	// Do not copy response bodies or credential-bearing diagnostics into a report.
	child.Stderr = io.Discard
	if err := child.Run(); err != nil || stdout.Len() != 0 {
		return 1
	}
	return 0
}

func waitCommandHook(state, provider, event string) error {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
		if err != nil {
			return err
		}
		rows, err := db.Query(`SELECT record_json FROM bee_thread_records WHERE kind = 'observation' AND source = 'bee' ORDER BY sequence`)
		if err != nil {
			db.Close()
			return err
		}
		found := false
		for rows.Next() {
			var text string
			if err := rows.Scan(&text); err != nil {
				rows.Close()
				db.Close()
				return err
			}
			var record struct {
				Body struct {
					Data struct {
						Name    string `json:"event_name"`
						Payload string `json:"payload_json"`
					} `json:"data"`
				} `json:"body"`
			}
			if json.Unmarshal([]byte(text), &record) != nil || record.Body.Data.Name != "bee.harness.hook" {
				continue
			}
			var payload struct {
				Event     string         `json:"event"`
				Ambiguous bool           `json:"ambiguous"`
				Fields    map[string]any `json:"fields"`
			}
			if json.Unmarshal([]byte(record.Body.Data.Payload), &payload) != nil || payload.Event != event || payload.Fields["session_id"] != "native-"+provider+"-hook-session" {
				continue
			}
			identityOK := payload.Ambiguous && payload.Fields["tool_use_id"] == nil
			if provider == "grok" && event == "PreToolUse" {
				identityOK = !payload.Ambiguous && payload.Fields["tool_use_id"] == "tool-1"
			}
			if !identityOK || strings.Contains(text, "BEE_PRIVATE_HOOK_CONTENT") || strings.Contains(text, "/private/hook-transcript") {
				rows.Close()
				db.Close()
				return errors.New("command hook changed occurrence identity or retained private content")
			}
			found = true
		}
		err = rows.Err()
		rows.Close()
		db.Close()
		if err != nil {
			return err
		}
		if found {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("%s %s observation was not committed", provider, event)
}

// runHookProbe submits one Claude PreToolUse event using the URL and token
// environment named by the host-delivered --settings argument. The helper is
// invoked by the disposable Claude executable, so the token never crosses the
// test process's diagnostic or report paths.
func runHookProbe(args []string) int {
	var settingsLiteral string
	for index, arg := range args {
		if arg == "--settings" && index+1 < len(args) {
			settingsLiteral = args[index+1]
			break
		}
	}
	if settingsLiteral == "" {
		return 1
	}
	var settings map[string]any
	if json.Unmarshal([]byte(settingsLiteral), &settings) != nil {
		return 1
	}
	hooks, ok := settings["hooks"].(map[string]any)
	if !ok {
		return 1
	}
	entries, ok := hooks["PreToolUse"].([]any)
	if !ok || len(entries) == 0 {
		return 1
	}
	entry, ok := entries[0].(map[string]any)
	if !ok {
		return 1
	}
	handlers, ok := entry["hooks"].([]any)
	if !ok || len(handlers) == 0 {
		return 1
	}
	handler, ok := handlers[0].(map[string]any)
	if !ok {
		return 1
	}
	url, ok := handler["url"].(string)
	if !ok || !strings.HasPrefix(url, "http://127.0.0.1:") || !strings.Contains(url, "/hook/") {
		return 1
	}
	headers, ok := handler["headers"].(map[string]any)
	if !ok {
		return 1
	}
	authorization, ok := headers["Authorization"].(string)
	if !ok || !strings.HasPrefix(authorization, "Bearer ${") || !strings.HasSuffix(authorization, "}") {
		return 1
	}
	environment := strings.TrimSuffix(strings.TrimPrefix(authorization, "Bearer ${"), "}")
	token := os.Getenv(environment)
	if token == "" {
		return 1
	}
	payload := map[string]any{
		"hook_event_name": "PreToolUse",
		"session_id":      "native-recovery-session",
		"prompt_id":       "native-recovery-prompt",
		"tool_use_id":     "native-recovery-tool",
		"tool_name":       "Bash",
		"tool_input":      map[string]any{"command": "true"},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return 1
	}
	request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return 1
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 10 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		return 1
	}
	_, _ = io.Copy(io.Discard, response.Body)
	_ = response.Body.Close()
	if response.StatusCode != http.StatusAccepted {
		return 1
	}
	return 0
}

func managedLaunch(binary, provider string, machineLogin bool, customConfig ...bool) (result error) {
	root, err := os.MkdirTemp("", "bee-project-launch-proof-")
	if err != nil {
		return err
	}
	defer func() {
		if result == nil {
			_ = os.RemoveAll(root)
		} else {
			fmt.Fprintln(os.Stderr, "Managed launch fixture retained:", root)
		}
	}()
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	report := filepath.Join(root, "launch-paths")
	mcpReport := filepath.Join(root, "mcp-report")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		return err
	}
	providerDirectory, loginFile := ".codex", "auth.json"
	selection := "\x1b[B\x1b[B\r"
	label := "Codex"
	if provider == "claude" {
		providerDirectory, loginFile = ".claude", ".credentials.json"
		selection, label = "\x1b[B\r", "Claude"
	}
	fixtureLogin := `{"fixture":"machine-login"}`
	fixtureOnboarding := `{"consumerOnboardingComplete":true,"onboardingComplete":true,"fixture":"machine-setup"}`
	fixtureGrokConfig := "[ui]\ntheme = \"dark\"\n[permission]\ndefault = \"ask\"\n[mcp_servers.user_fixture]\nurl = \"http://127.0.0.1:9/mcp\"\n"
	if provider == "agy" {
		providerDirectory, loginFile = filepath.Join(".gemini", "antigravity-cli"), "antigravity-oauth-token"
		selection, label = "\r", "Antigravity"
		fixtureLogin = "opaque-fixture-login\x00bytes"
	}
	if provider == "grok" {
		providerDirectory, loginFile = ".grok", "auth.json"
		selection, label = "\x1b[B\x1b[B\x1b[B\r", "Grok"
	}
	loginRoot := filepath.Join(home, providerDirectory)
	var extraEnv []string
	configVariable := ""
	if len(customConfig) > 0 && customConfig[0] {
		configVariable = "CODEX_HOME"
		if provider == "claude" {
			configVariable = "CLAUDE_CONFIG_DIR"
		}
		loginRoot = filepath.Join(root, "custom-agent-config")
		extraEnv = []string{configVariable + "=" + loginRoot}
	}
	if machineLogin {
		if err := os.MkdirAll(loginRoot, 0700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(loginRoot, loginFile), []byte(fixtureLogin), 0600); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(loginRoot, "machine-only-state"), []byte("not projected"), 0600); err != nil {
			return err
		}
		if provider == "agy" {
			cache := filepath.Join(home, providerDirectory, "cache")
			if err := os.MkdirAll(cache, 0700); err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(cache, "onboarding.json"), []byte(fixtureOnboarding), 0600); err != nil {
				return err
			}
		}
	}
	if provider == "grok" {
		if err := os.MkdirAll(filepath.Join(home, ".grok"), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(home, ".grok", "config.toml"), []byte(fixtureGrokConfig), 0600); err != nil {
			return err
		}
	}
	cli := filepath.Join(project, "bin", provider)
	helper := filepath.Join(filepath.Dir(os.Args[0]), filepath.Base(os.Args[0]))
	if resolved, helperErr := filepath.EvalSymlinks(os.Args[0]); helperErr == nil {
		helper = resolved
	}
	script := "#!/bin/sh\nprintf '%s\\n%s\\n' \"$PWD\" \"$HOME\" > " + shellQuote(report) +
		"\nif ! " + shellQuote(helper) + " mcp-probe " + shellQuote(provider) + " " + shellQuote(mcpReport) + " \"$@\"; then exit 1; fi\nprintf 'BEE_MANAGED_AGENT_READY\\n'\nprintf 'retained' > \"$HOME/bee-session-proof\"\nIFS= read -r answer\n"
	if configVariable != "" {
		script = strings.Replace(script, "\nif ! ", "\nprintf '%s\\n' \"$"+configVariable+"\" >> "+shellQuote(report)+"\nif ! ", 1)
	}
	if provider == "agy" || provider == "grok" {
		probe := shellQuote(helper) + " command-hook-probe " + shellQuote(provider)
		script = strings.Replace(script, "printf 'BEE_MANAGED_AGENT_READY", probe+" PreToolUse \"$@\" || exit 1\nprintf 'BEE_MANAGED_AGENT_READY", 1)
		script += probe + " Stop \"$@\" || exit 1\n"
	}
	if provider == "agy" {
		capture := "config_root=\nprevious=\nfor argument in \"$@\"; do if [ \"$previous\" = --add-dir ]; then config_root=$argument; break; fi; previous=$argument; done\n[ -n \"$config_root\" ]\nprintf '%s\\n' \"$config_root\" >> " + shellQuote(report) + "\n"
		script = strings.Replace(script, "\nif ! ", "\n"+capture+"if ! ", 1)
	}
	if err := os.WriteFile(cli, []byte(script), 0700); err != nil {
		return err
	}
	directAlias := machineLogin && !(len(customConfig) > 0 && customConfig[0])
	arguments := []string{"agent"}
	if directAlias {
		arguments = []string{provider}
	}
	ui, err := newDesktopWithArguments(binary, project, state, home, arguments, extraEnv...)
	if err != nil {
		return err
	}
	var retained *owner
	defer func() {
		ui.close()
		_ = retained.stop()
		_ = stopFixtureOwners(binary, state)
	}()
	if !directAlias {
		if err := ui.waitFor(label, 25*time.Second); err != nil {
			return err
		}
		for step := 0; step < strings.Count(selection, "\x1b[B"); step++ {
			_, before, _ := ui.snapshot()
			if err := ui.send("\x1b[B"); err != nil {
				return err
			}
			if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
				return fmt.Errorf("select profile step %d: %w", step+1, err)
			}
		}
		for _, detail := range []string{"Configured folder", "No instructions", "7 tools configured"} {
			if err := ui.waitFor(detail, 5*time.Second); err != nil {
				return fmt.Errorf("selected profile summary: %w", err)
			}
		}
		if err := ui.send("\r"); err != nil {
			return err
		}
	}
	if err := ui.waitFor("BEE_MANAGED_AGENT_READY", 25*time.Second); err != nil {
		// This report contains only HTTP status codes and Boolean checks. Keep
		// configuration and credentials out of readiness failure diagnostics.
		if reportData, readError := os.ReadFile(mcpReport); readError == nil {
			var status mcpProbeReport
			if json.Unmarshal(reportData, &status) == nil {
				return fmt.Errorf("%w; MCP probe: %+v", err, status)
			}
		}
		return err
	}
	if err := assertManagedRoute(state, provider); err != nil {
		return fmt.Errorf("managed %s route proof: %w", provider, err)
	}
	mcpData, err := os.ReadFile(mcpReport)
	if err != nil {
		return fmt.Errorf("read managed MCP report: %w", err)
	}
	var mcpResult mcpProbeReport
	if err := json.Unmarshal(mcpData, &mcpResult); err != nil || mcpResult.Provider != provider ||
		mcpResult.InitializeStatus != http.StatusOK || mcpResult.ListStatus != http.StatusOK ||
		mcpResult.ReadStatus != http.StatusOK || mcpResult.WaitStatus != http.StatusOK || mcpResult.MessageStatus != http.StatusOK ||
		!mcpResult.ReadOK || !mcpResult.WaitOK || !mcpResult.MessageOK || !mcpResult.MessageReplayOK ||
		!mcpResult.ReadAnnotationOK || !mcpResult.WaitAnnotationOK || !mcpResult.MessageWriteOK ||
		strings.Join(mcpResult.Tools, ",") != "components,delivery,docs,thread_message,thread_read,thread_wait,workspace" {
		return fmt.Errorf("managed MCP report did not prove gateway access: %q", string(mcpData))
	}
	retained, err = ownerChild(ui.cmd.Process.Pid, binary, state, 10*time.Second)
	if err != nil {
		return err
	}
	paths, err := os.ReadFile(report)
	if err != nil {
		return fmt.Errorf("read managed launch paths: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(paths)), "\n")
	expectedPaths := 2
	if configVariable != "" {
		expectedPaths = 3
	}
	if provider == "agy" {
		expectedPaths = 3
	}
	if len(lines) != expectedPaths {
		return fmt.Errorf("managed launch wrote malformed paths: %q", string(paths))
	}
	projectPath, err := filepath.EvalSymlinks(project)
	if err != nil {
		return err
	}
	childCWD, err := filepath.EvalSymlinks(lines[0])
	if err != nil || childCWD != projectPath {
		return fmt.Errorf("managed agent cwd = %q, want %q", lines[0], projectPath)
	}
	childHome, err := filepath.EvalSymlinks(lines[1])
	if err != nil {
		return fmt.Errorf("resolve managed HOME %q: %w", lines[1], err)
	}
	if childHome == projectPath {
		return errors.New("managed agent HOME was the project directory")
	}
	inheritsHome := provider == "claude" || provider == "codex" || provider == "agy"
	if inheritsHome {
		expectedHome, err := filepath.EvalSymlinks(home)
		if err != nil || childHome != expectedHome {
			return errors.New("managed agent did not inherit the global user home")
		}
	}
	var agyCustomizationRoot string
	if provider == "agy" {
		configurationRoot, err := filepath.EvalSymlinks(lines[2])
		if err != nil {
			return fmt.Errorf("resolve Agy customization root %q: %w", lines[2], err)
		}
		agyCustomizationRoot = configurationRoot
		statePath, err := filepath.EvalSymlinks(state)
		if err != nil {
			return fmt.Errorf("resolve Bee state root: %w", err)
		}
		relative, err := filepath.Rel(statePath, configurationRoot)
		if err != nil || relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return errors.New("Agy customization root is outside Bee-owned state")
		}
		if configurationRoot == childHome || configurationRoot == projectPath {
			return errors.New("Agy customization root overlaps HOME or project")
		}
		info, err := os.Stat(configurationRoot)
		if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
			return errors.New("Agy customization root is not a private directory")
		}
		data, err := os.ReadFile(filepath.Join(configurationRoot, ".agents", "mcp_config.json"))
		if err != nil {
			return err
		}
		var document struct {
			Servers map[string]struct {
				Headers map[string]string `json:"headers"`
			} `json:"mcpServers"`
		}
		if json.Unmarshal(data, &document) != nil {
			return errors.New("invalid Agy additive MCP document")
		}
		token := strings.TrimPrefix(document.Servers["bee"].Headers["Authorization"], "Bearer ")
		if token == "" || strings.Contains(token, "${") {
			return errors.New("Agy MCP credential was not materialized")
		}
		db, err := openRecoveryDB(filepath.Join(state, "placement.db"))
		if err != nil {
			return err
		}
		var leaked int
		err = db.QueryRow(`SELECT (SELECT count(*) FROM bee_placement_attempts WHERE instr(request_json, ?) > 0) + (SELECT count(*) FROM bee_placement_evidence WHERE instr(detail, ?) > 0)`, token, token).Scan(&leaked)
		db.Close()
		if err != nil {
			return err
		}
		if leaked != 0 {
			return errors.New("Agy MCP credential reached a recorded template or receipt")
		}
		for _, path := range []string{
			filepath.Join(childHome, ".gemini", "config", "mcp_config.json"),
			filepath.Join(childHome, ".gemini", "config", "hooks.json"),
			filepath.Join(childHome, ".gemini", "GEMINI.md"),
		} {
			if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
				return errors.New("Bee generated Agy configuration in the global home")
			}
		}
	}
	if provider == "grok" {
		base, err := os.ReadFile(filepath.Join(childHome, ".grok", ".bee-global-config.toml"))
		if err != nil || string(base) != fixtureGrokConfig {
			return errors.New("Grok global configuration was not snapshotted into the private composition base")
		}
		beeConfig, err := os.ReadFile(filepath.Join(childHome, ".grok", "config.toml"))
		if err != nil || !strings.Contains(string(beeConfig), "[mcp_servers.bee]") || !strings.Contains(string(beeConfig), "[mcp_servers.user_fixture]") ||
			(!strings.Contains(string(beeConfig), "theme = 'dark'") && !strings.Contains(string(beeConfig), `theme = "dark"`)) {
			return errors.New("Grok private configuration did not compose global settings with the Bee MCP subtree")
		}
		global, err := os.ReadFile(filepath.Join(home, ".grok", "config.toml"))
		if err != nil || string(global) != fixtureGrokConfig {
			return errors.New("Bee changed the global Grok configuration")
		}
	}
	childLoginRoot := filepath.Join(childHome, providerDirectory)
	if configVariable != "" {
		if lines[2] != loginRoot {
			return errors.New("managed agent did not inherit its custom configuration directory")
		}
		childLoginRoot = lines[2]
	}
	login, loginErr := os.ReadFile(filepath.Join(childLoginRoot, loginFile))
	if provider == "agy" {
		setup, setupErr := os.ReadFile(filepath.Join(childHome, providerDirectory, "cache", "onboarding.json"))
		if machineLogin {
			if setupErr != nil || string(setup) != fixtureOnboarding {
				return errors.New("machine onboarding state was not projected exactly")
			}
		} else if !os.IsNotExist(setupErr) {
			return errors.New("absent machine onboarding state was fabricated")
		}
	}
	if machineLogin {
		if loginErr != nil || string(login) != fixtureLogin {
			return errors.New("machine login was not available at the selected agent configuration directory")
		}
		_, stateErr := os.Stat(filepath.Join(childLoginRoot, "machine-only-state"))
		if inheritsHome && stateErr != nil {
			return errors.New("global agent state was not inherited")
		}
		if !inheritsHome && !os.IsNotExist(stateErr) {
			return errors.New("unrelated machine state appeared in private home")
		}
		info, err := os.Lstat(filepath.Join(childLoginRoot, loginFile))
		if err != nil || !info.Mode().IsRegular() {
			return errors.New("selected login is not a regular file")
		}
	} else {
		if !os.IsNotExist(loginErr) {
			return errors.New("absent machine login unexpectedly produced a login file")
		}
		if provider != "grok" {
			if _, err := os.Stat(filepath.Join(home, providerDirectory)); !os.IsNotExist(err) {
				return errors.New("launch created a machine credential directory")
			}
		}
	}
	_, identityErr := os.Stat(filepath.Join(childHome, ".bee-retained-login-ready.json"))
	if inheritsHome && !os.IsNotExist(identityErr) {
		return errors.New("Bee wrote retained-login metadata into global home")
	}
	if !inheritsHome && identityErr != nil {
		return fmt.Errorf("login source binding missing: %w", identityErr)
	}
	marker := filepath.Join(childHome, "bee-session-proof")
	data, err := os.ReadFile(marker)
	if err != nil || string(data) != "retained" {
		return fmt.Errorf("managed session marker = %q, err=%v", string(data), err)
	}
	if provider == "agy" || provider == "grok" {
		if err := waitCommandHook(state, provider, "PreToolUse"); err != nil {
			return err
		}
		activity := "Using tool"
		if provider == "agy" {
			activity = "Activity uncertain"
		}
		titleEvidence := activity
		if directAlias {
			titleEvidence = "Grok CLI · Using"
			if provider == "agy" {
				titleEvidence = "Antigravity CLI · Act"
			}
		}
		if err := ui.waitFor(titleEvidence, 5*time.Second); err != nil {
			return fmt.Errorf("committed %s hook title: %w", provider, err)
		}
	}
	if err := ui.send("finish\r"); err != nil {
		return err
	}
	if provider == "agy" || provider == "grok" {
		if err := waitCommandHook(state, provider, "Stop"); err != nil {
			return err
		}
	}
	// Allow the selected app to finish before detaching the client.
	time.Sleep(300 * time.Millisecond)
	if err := ui.quit(); err != nil {
		return err
	}
	if err := retained.stop(); err != nil {
		return err
	}
	retained = nil
	data, err = os.ReadFile(marker)
	if err != nil || string(data) != "retained" {
		return fmt.Errorf("session marker did not survive node exit: %q, err=%v", string(data), err)
	}
	if agyCustomizationRoot != "" {
		if _, err := os.Stat(filepath.Join(agyCustomizationRoot, ".agents", "mcp_config.json")); err != nil {
			return fmt.Errorf("Agy session customization did not survive node exit: %w", err)
		}
	}
	if provider == "grok" {
		global, err := os.ReadFile(filepath.Join(home, ".grok", "config.toml"))
		if err != nil || string(global) != fixtureGrokConfig {
			return errors.New("Grok launch or shutdown changed the global configuration")
		}
		base, err := os.ReadFile(filepath.Join(childHome, ".grok", ".bee-global-config.toml"))
		if err != nil || string(base) != fixtureGrokConfig {
			return errors.New("Grok private composition base did not survive node exit")
		}
	}
	return nil
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "picker" {
		binary, err := filepath.Abs(os.Args[2])
		if err == nil {
			binary, err = filepath.EvalSymlinks(binary)
		}
		if err == nil {
			err = defaultPicker(binary)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("Native Agent picker: editing, unavailable launch, refresh, F12, close and no thread work passed")
		return
	}
	if len(os.Args) == 4 && os.Args[1] == "managed" {
		provider := os.Args[2]
		if provider != "grok" && provider != "agy" && provider != "claude" && provider != "codex" {
			os.Exit(2)
		}
		binary, err := filepath.Abs(os.Args[3])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		for _, present := range []bool{false, true} {
			if err := managedLaunch(binary, provider, present); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
		if provider == "claude" || provider == "codex" {
			if err := managedLaunch(binary, provider, true, true); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
		}
		fmt.Println("Managed", provider, "login, MCP and lifecycle checks passed")
		return
	}
	if len(os.Args) >= 4 && os.Args[1] == "command-hook-probe" {
		os.Exit(runCommandHookProbe(os.Args[2], os.Args[3], os.Args[4:]))
	}
	if len(os.Args) >= 4 && os.Args[1] == "mcp-probe" {
		os.Exit(runMCPProbe(os.Args[2], os.Args[3], os.Args[4:]))
	}
	if len(os.Args) >= 3 && os.Args[1] == "hook-probe" {
		os.Exit(runHookProbe(os.Args[2:]))
	}
	if len(os.Args) == 3 && os.Args[1] == "recovery" {
		binary, resolveError := filepath.Abs(os.Args[2])
		if resolveError != nil {
			fmt.Fprintln(os.Stderr, resolveError)
			os.Exit(1)
		}
		binary, resolveError = filepath.EvalSymlinks(binary)
		if resolveError != nil {
			fmt.Fprintln(os.Stderr, resolveError)
			os.Exit(1)
		}
		if recoveryError := nativeAgentRecovery(binary); recoveryError != nil {
			fmt.Fprintf(os.Stderr, "native Agent recovery acceptance failed: %v\n", recoveryError)
			os.Exit(1)
		}
		fmt.Println("Native Agent recovery: acknowledged Claude hook, retained HOME, stable application identity, fresh resumed attempt and fresh gateway binding across owner restart")
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "recovery-crash" {
		binary, resolveError := filepath.Abs(os.Args[2])
		if resolveError != nil {
			fmt.Fprintln(os.Stderr, resolveError)
			os.Exit(1)
		}
		binary, resolveError = filepath.EvalSymlinks(binary)
		if resolveError != nil {
			fmt.Fprintln(os.Stderr, resolveError)
			os.Exit(1)
		}
		if recoveryError := nativeAgentRecoveryCrash(binary); recoveryError != nil {
			fmt.Fprintf(os.Stderr, "native Agent crash recovery acceptance failed: %v\n", recoveryError)
			os.Exit(1)
		}
		fmt.Println("Native Agent crash recovery: exact owner SIGKILL, native identity inspection and saved Agent continuation")
		return
	}
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: native_agent_selector BEE_BINARY")
		os.Exit(2)
	}
	binary, err := filepath.Abs(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	binary, err = filepath.EvalSymlinks(binary)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := defaultPicker(binary); err != nil {
		fmt.Fprintf(os.Stderr, "default Agent picker acceptance failed: %v\n", err)
		os.Exit(1)
	}
	if err := savedProfileLaunch(binary); err != nil {
		fmt.Fprintf(os.Stderr, "saved profile launch acceptance failed: %v\n", err)
		os.Exit(1)
	}
	if err := rawManagedAliasRefusal(binary); err != nil {
		fmt.Fprintf(os.Stderr, "managed alias raw-argument refusal failed: %v\n", err)
		os.Exit(1)
	}
	for _, provider := range []string{"codex", "claude", "agy", "grok"} {
		for _, present := range []bool{false, true} {
			if err := managedLaunch(binary, provider, present); err != nil {
				fmt.Fprintf(os.Stderr, "managed %s launch (machine login=%v) failed: %v\n", provider, present, err)
				os.Exit(1)
			}
		}
	}
	fmt.Println("Native bee agent: five default profiles, no-work picker, F12, Escape close, project cwd, separate retained HOME durable session file, and present/absent machine login")
}
