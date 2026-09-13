// SPDX-License-Identifier: MIT
// Source-free acceptance for the public `bee agent` picker and managed launch.
package main

import (
	"bytes"
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

func newDesktop(binary, project, state, home string) (*desktop, error) {
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
	cmd := exec.Command(binary, "--state-dir", state, "agent")
	cmd.Dir = project
	cmd.Env = env
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
		"BEE_RUNTIME": true, "USER": true,
		"BEE_WORKSPACE_DB": true, "BEE_THREADS_DB": true, "BEE_APPROVALS_DB": true,
		"BEE_RESOURCES_DB": true, "BEE_CREDENTIALS_DB": true, "BEE_PLACEMENT_DB": true,
		"BEE_GATEWAY_DB": true, "BEE_NODE_DB": true, "BEE_GOVERNANCE_DB": true,
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
			return fmt.Errorf("timed out waiting for refreshed %q\n%s", text, string(log))
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
	stateMatch, startMatch, commandMatch := false, false, false
	for i, arg := range args {
		if arg == state && i > 0 && args[i-1] == "--state-dir" {
			stateMatch = true
		}
		if arg == "start" {
			startMatch = true
		}
		if arg == "--command" {
			commandMatch = true
			if i+1 >= len(args) || args[i+1] == "" {
				return false
			}
		}
	}
	return stateMatch && startMatch && commandMatch
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
	defer unix.Close(o.fd)
	wait := func(timeout time.Duration) bool {
		poll := []unix.PollFd{{Fd: int32(o.fd), Events: unix.POLLIN}}
		_, err := unix.Poll(poll, int(timeout/time.Millisecond))
		return err == nil && poll[0].Revents != 0
	}
	if wait(0) {
		return nil
	}
	if err := unix.PidfdSendSignal(o.fd, unix.SIGTERM, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
		return err
	}
	if wait(10 * time.Second) {
		return nil
	}
	if err := unix.PidfdSendSignal(o.fd, unix.SIGKILL, nil, 0); err != nil && !errors.Is(err, unix.ESRCH) {
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
	for _, profile := range []string{"Antigravity", "Claude", "Codex", "Grok"} {
		latest, _, _ := ui.snapshot()
		if !ui.observed(profile, 0) {
			return fmt.Errorf("picker omitted default profile %q\n%s", profile, latest)
		}
	}
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
	_, before, _ := ui.snapshot()
	if err := ui.send("\x1b[24~"); err != nil {
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

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
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
	ReadAnnotationOK bool     `json:"read_annotation_ok"`
	WaitAnnotationOK bool     `json:"wait_annotation_ok"`
	MessageWriteOK   bool     `json:"message_write_annotation_ok"`
}

// mcpProbeConfig extracts only the URL and token environment name from the
// driver's generated configuration. The token itself is read from the child
// environment and is never written to a report or diagnostic.
func mcpProbeConfig(provider string, args []string) (string, string, bool) {
	if provider == "claude" {
		for index, arg := range args {
			if arg != "--mcp-config" || index+1 >= len(args) {
				continue
			}
			var document struct {
				Servers map[string]struct {
					URL     string            `json:"url"`
					Headers map[string]string `json:"headers"`
				} `json:"mcpServers"`
			}
			if json.Unmarshal([]byte(args[index+1]), &document) != nil {
				return "", "", false
			}
			server, ok := document.Servers["bee"]
			if !ok || server.URL == "" {
				return "", "", false
			}
			authorization := server.Headers["Authorization"]
			const prefix, suffix = "Bearer ${", "}"
			if !strings.HasPrefix(authorization, prefix) || !strings.HasSuffix(authorization, suffix) {
				return "", "", false
			}
			name := strings.TrimSuffix(strings.TrimPrefix(authorization, prefix), suffix)
			if name == "" || strings.ContainsAny(name, "=\x00\r\n") {
				return "", "", false
			}
			return server.URL, name, true
		}
		return "", "", false
	}
	if provider != "codex" {
		return "", "", false
	}
	config, err := os.ReadFile(filepath.Join(os.Getenv("HOME"), ".codex", "config.toml"))
	if err != nil {
		return "", "", false
	}
	var url, tokenName string
	inBeeServer := false
	for _, line := range strings.Split(string(config), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			inBeeServer = line == "[mcp_servers.bee]"
			continue
		}
		if inBeeServer && strings.HasPrefix(line, "url = \"") && strings.HasSuffix(line, "\"") {
			url = strings.TrimSuffix(strings.TrimPrefix(line, "url = \""), "\"")
		}
		if inBeeServer && strings.HasPrefix(line, "bearer_token_env_var = \"") && strings.HasSuffix(line, "\"") {
			tokenName = strings.TrimSuffix(strings.TrimPrefix(line, "bearer_token_env_var = \""), "\"")
		}
	}
	return url, tokenName, url != "" && tokenName != ""
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
	url, tokenName, ok := mcpProbeConfig(provider, args)
	if !ok || os.Getenv(tokenName) == "" {
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
	token := os.Getenv(tokenName)
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
	if json.Unmarshal(listReply.Result, &listed) != nil || len(listed.Tools) != 3 {
		return 1
	}
	for _, tool := range listed.Tools {
		if tool.Name == "" || tool.Annotations.ReadOnlyHint == nil {
			return 1
		}
		switch tool.Name {
		case "thread_read":
			report.ReadAnnotationOK = *tool.Annotations.ReadOnlyHint
		case "thread_wait":
			report.WaitAnnotationOK = *tool.Annotations.ReadOnlyHint
		case "thread_message":
			report.MessageWriteOK = !*tool.Annotations.ReadOnlyHint
		default:
			return 1
		}
		report.Tools = append(report.Tools, tool.Name)
	}
	sort.Strings(report.Tools)
	if len(report.Tools) != 3 || report.Tools[0] != "thread_message" || report.Tools[1] != "thread_read" || report.Tools[2] != "thread_wait" ||
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

func managedLaunch(binary, provider string, machineLogin bool) error {
	root, err := os.MkdirTemp("", "bee-project-launch-proof-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
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
	const fixtureLogin = `{"fixture":"machine-login"}`
	if machineLogin {
		if err := os.MkdirAll(filepath.Join(home, providerDirectory), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(home, providerDirectory, loginFile), []byte(fixtureLogin), 0600); err != nil {
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
	if err := os.WriteFile(cli, []byte(script), 0700); err != nil {
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
	if err := ui.waitFor(label, 25*time.Second); err != nil {
		return err
	}
	if err := ui.send(strings.TrimSuffix(selection, "\r")); err != nil {
		return err
	}
	for _, detail := range []string{"Configured folder", "No instructions", "3 tools configured"} {
		if err := ui.waitFor(detail, 5*time.Second); err != nil {
			return fmt.Errorf("selected profile summary: %w", err)
		}
	}
	if err := ui.send("\r"); err != nil {
		return err
	}
	if err := ui.waitFor("BEE_MANAGED_AGENT_READY", 25*time.Second); err != nil {
		return err
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
		strings.Join(mcpResult.Tools, ",") != "thread_message,thread_read,thread_wait" {
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
	if len(lines) != 2 {
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
	login, loginErr := os.ReadFile(filepath.Join(childHome, providerDirectory, loginFile))
	if machineLogin {
		if loginErr != nil || string(login) != fixtureLogin {
			return errors.New("machine login was not seeded into private home")
		}
	} else {
		if !os.IsNotExist(loginErr) {
			return errors.New("absent machine login unexpectedly produced a login file")
		}
		if _, err := os.Stat(filepath.Join(home, providerDirectory)); !os.IsNotExist(err) {
			return errors.New("launch created a machine credential directory")
		}
	}
	if _, err := os.Stat(filepath.Join(childHome, ".bee-retained-login-ready.json")); err != nil {
		return fmt.Errorf("login source binding missing: %w", err)
	}
	marker := filepath.Join(childHome, "bee-session-proof")
	data, err := os.ReadFile(marker)
	if err != nil || string(data) != "retained" {
		return fmt.Errorf("managed session marker = %q, err=%v", string(data), err)
	}
	if err := ui.send("finish\r"); err != nil {
		return err
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
	return nil
}

func main() {
	if len(os.Args) >= 4 && os.Args[1] == "mcp-probe" {
		os.Exit(runMCPProbe(os.Args[2], os.Args[3], os.Args[4:]))
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
	for _, provider := range []string{"codex", "claude"} {
		for _, present := range []bool{false, true} {
			if err := managedLaunch(binary, provider, present); err != nil {
				fmt.Fprintf(os.Stderr, "managed %s launch (machine login=%v) failed: %v\n", provider, present, err)
				os.Exit(1)
			}
		}
	}
	fmt.Println("Native bee agent: four default profiles, no-work picker, F12, Escape close, project cwd, separate retained HOME durable session file, and present/absent machine login")
}
