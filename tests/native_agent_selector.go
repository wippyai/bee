// SPDX-License-Identifier: MIT
// Source-free acceptance for the public `bee agent` picker and managed launch.
package main

import (
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

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
	d := &desktop{cmd: cmd, terminal: terminal, mu: make(chan struct{}, 1)}
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
		d.latest = visible(d.pending[len(frameStart):contentEnd])
		d.frame++
		d.history = append(d.history, observedFrame{sequence: d.frame, text: d.latest})
		if len(d.history) > 32 {
			d.history = d.history[len(d.history)-32:]
		}
		d.pending = append([]byte(nil), d.pending[contentEnd+len(frameEnd):]...)
	}
}

// visible removes terminal control sequences while preserving the frame's text.
// Synchronized frames may contain only changed cells. This extracts emitted
// text; it does not reconstruct the current screen.
func visible(input []byte) string {
	var out strings.Builder
	for i := 0; i < len(input); {
		if input[i] != 0x1b {
			if input[i] >= 0x20 || input[i] == '\n' || input[i] == '\r' || input[i] == '\t' {
				out.WriteByte(input[i])
			}
			i++
			continue
		}
		i++
		if i == len(input) {
			break
		}
		if input[i] == '[' {
			i++
			for i < len(input) {
				c := input[i]
				i++
				if c >= 0x40 && c <= 0x7e {
					break
				}
			}
			continue
		}
		// OSC, DCS and the other string controls terminate at BEL or ST.
		if input[i] == ']' || input[i] == 'P' || input[i] == '^' || input[i] == '_' || input[i] == 'X' {
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
			continue
		}
		// A two-byte ESC command has no visible text.
		i++
	}
	return out.String()
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

func managedLaunch(binary string, machineLogin bool) error {
	root, err := os.MkdirTemp("", "bee-project-launch-proof-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	report := filepath.Join(root, "launch-paths")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		return err
	}
	const fixtureLogin = `{"fixture":"machine-login"}`
	if machineLogin {
		if err := os.MkdirAll(filepath.Join(home, ".codex"), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(home, ".codex", "auth.json"), []byte(fixtureLogin), 0600); err != nil {
			return err
		}
	}
	cli := filepath.Join(project, "bin", "codex")
	script := "#!/bin/sh\nprintf '%s\\n%s\\n' \"$PWD\" \"$HOME\" > " + shellQuote(report) + "\nprintf 'BEE_MANAGED_CODEX_READY\\n'\nprintf 'retained' > \"$HOME/bee-session-proof\"\nIFS= read -r answer\n"
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
	if err := ui.waitFor("Codex", 25*time.Second); err != nil {
		return err
	}
	if err := ui.send("\x1b[B\x1b[B\r"); err != nil {
		return err
	}
	if err := ui.waitFor("BEE_MANAGED_CODEX_READY", 25*time.Second); err != nil {
		return err
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
		return fmt.Errorf("managed Codex cwd = %q, want %q", lines[0], projectPath)
	}
	childHome, err := filepath.EvalSymlinks(lines[1])
	if err != nil {
		return fmt.Errorf("resolve managed HOME %q: %w", lines[1], err)
	}
	if childHome == projectPath {
		return errors.New("managed Codex HOME was the project directory")
	}
	login, loginErr := os.ReadFile(filepath.Join(childHome, ".codex", "auth.json"))
	if machineLogin {
		if loginErr != nil || string(login) != fixtureLogin {
			return errors.New("machine login was not seeded into private home")
		}
	} else {
		if !os.IsNotExist(loginErr) {
			return errors.New("absent machine login unexpectedly produced a login file")
		}
		if _, err := os.Stat(filepath.Join(home, ".codex")); !os.IsNotExist(err) {
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
	for _, present := range []bool{false, true} {
		if err := managedLaunch(binary, present); err != nil {
			fmt.Fprintf(os.Stderr, "managed Agent launch (machine login=%v) failed: %v\n", present, err)
			os.Exit(1)
		}
	}
	fmt.Println("Native bee agent: four default profiles, no-work picker, F12, Escape close, project cwd, separate retained HOME durable session file, and present/absent machine login")
}
