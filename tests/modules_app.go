// SPDX-License-Identifier: MIT
// Source/pack acceptance for the real Modules application process. The Hub
// facade is a deterministic fixture so this gate exercises the app boundary,
// presenter and confirmation flow without publishing registry mutations.
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
	"unsafe"
)

const fixtureFacade = `local function handle(raw: unknown): {[string]: unknown}
    if type(raw) ~= "table" then return {ok = false, replayed = false} end
    if raw.operation == "catalog" then
        return {ok = true, replayed = false, value = {total = 1, items = {{
            component = "bee/example", title = "Preview fixture", description = "Packaged module",
            latest_version = "1.0.0"}}}}
    elseif raw.operation == "details" then
        return {ok = true, replayed = false, value = {component = "bee/example", title = "Preview fixture",
            description = "Packaged module", readme = "# Fixture guide\nRead this before installing.\nPackage usage and configuration.", page = 1, total_versions = 2,
            versions = {{version = "1.0.0", yanked = false}, {version = "0.9.0", yanked = false}}}}
    elseif raw.operation == "inspect" then
        return {ok = true, replayed = false, value = {requirements = {missing = {}, bindings = {}}}}
    elseif raw.operation == "plan" then
        return {ok = true, replayed = false, value = {request = raw.request,
            digest = string.rep("a", 64), ready = true, base_revision = 1,
            modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {
                "fixture:01", "fixture:02", "fixture:03", "fixture:04", "fixture:05", "fixture:06",
                "fixture:07", "fixture:08", "fixture:09", "fixture:10", "fixture:11", "fixture:12",
                "fixture:last"}}}
    elseif raw.operation == "apply" then
        assert(raw.expected_digest == string.rep("a", 64), "confirmation lost the displayed digest")
        return {ok = true, replayed = false, value = {state = "complete", message = "Fixture confirmation received"}}
    end
    return {ok = false, replayed = false, code = "FIXTURE", message = "No fixture mutation"}
end
return {handle = handle}
`

type lockedBuffer struct {
	sync.Mutex
	data bytes.Buffer
}

func (b *lockedBuffer) Write(data []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	return b.data.Write(data)
}

func (b *lockedBuffer) snapshot() []byte {
	b.Lock()
	defer b.Unlock()
	return append([]byte(nil), b.data.Bytes()...)
}

type desktop struct {
	cmd      *exec.Cmd
	master   *os.File
	output   lockedBuffer
	finished chan error
	readDone chan struct{}
	waitErr  error
	exited   bool
	cancel   context.CancelFunc
	root     string
	mode     string
}

// terminalText applies the cursor and erase controls emitted by the real
// terminal presenter so checks observe the current screen instead of an old
// string that was later replaced during a redraw.
func terminalText(raw []byte) string {
	const width, height = 100, 30
	screen := make([][]rune, height)
	for row := range screen {
		screen[row] = make([]rune, width)
		for column := range screen[row] {
			screen[row][column] = ' '
		}
	}
	x, y, savedX, savedY := 0, 0, 0, 0
	clear := func() {
		for row := range screen {
			for column := range screen[row] {
				screen[row][column] = ' '
			}
		}
	}
	newline := func() {
		y++
		if y >= height {
			copy(screen, screen[1:])
			screen[height-1] = make([]rune, width)
			for column := range screen[height-1] {
				screen[height-1][column] = ' '
			}
			y = height - 1
		}
	}
	param := func(values []int, index, fallback int) int {
		if index >= len(values) || values[index] == 0 {
			return fallback
		}
		return values[index]
	}
	for i := 0; i < len(raw); {
		if raw[i] == 0x1b {
			if i+1 >= len(raw) {
				break
			}
			switch raw[i+1] {
			case '[':
				end := i + 2
				for end < len(raw) && (raw[end] < 0x40 || raw[end] > 0x7e) {
					end++
				}
				if end >= len(raw) {
					i = len(raw)
					continue
				}
				body, command := string(raw[i+2:end]), raw[end]
				private := strings.HasPrefix(body, "?")
				body = strings.TrimLeft(body, "?=>")
				parts := strings.Split(body, ";")
				values := make([]int, len(parts))
				for index, part := range parts {
					values[index], _ = strconv.Atoi(part)
				}
				count := param(values, 0, 1)
				switch command {
				case 'A':
					y = maxInt(0, y-count)
				case 'B':
					y = minInt(height-1, y+count)
				case 'C':
					x = minInt(width-1, x+count)
				case 'D':
					x = maxInt(0, x-count)
				case 'E':
					y = minInt(height-1, y+count)
					x = 0
				case 'F':
					y = maxInt(0, y-count)
					x = 0
				case 'G':
					x = minInt(width-1, maxInt(0, count-1))
				case 'H', 'f':
					y = minInt(height-1, maxInt(0, param(values, 0, 1)-1))
					x = minInt(width-1, maxInt(0, param(values, 1, 1)-1))
				case 'J':
					switch param(values, 0, 0) {
					case 2, 3:
						clear()
					case 0:
						for row := y; row < height; row++ {
							start := 0
							if row == y {
								start = x
							}
							for column := start; column < width; column++ {
								screen[row][column] = ' '
							}
						}
					case 1:
						for row := 0; row <= y; row++ {
							endColumn := width
							if row == y {
								endColumn = x + 1
							}
							for column := 0; column < endColumn; column++ {
								screen[row][column] = ' '
							}
						}
					}
				case 'K':
					start, end := x, width
					if param(values, 0, 0) == 1 {
						start, end = 0, x+1
					} else if param(values, 0, 0) == 2 {
						start = 0
					}
					for column := start; column < end; column++ {
						screen[y][column] = ' '
					}
				case 'd':
					y = minInt(height-1, maxInt(0, count-1))
				case 's':
					savedX, savedY = x, y
				case 'u':
					x, y = savedX, savedY
				case 'h':
					if private && strings.Contains(body, "1049") {
						clear()
						x, y = 0, 0
					}
				}
				i = end + 1
				continue
			case ']':
				end := i + 2
				for end < len(raw) && raw[end] != 0x07 && !(raw[end] == 0x1b && end+1 < len(raw) && raw[end+1] == '\\') {
					end++
				}
				if end < len(raw) && raw[end] == 0x1b {
					end++
				}
				i = minInt(len(raw), end+1)
				continue
			default:
				i += 2
				continue
			}
		}
		switch raw[i] {
		case '\r':
			x = 0
			i++
			continue
		case '\n':
			newline()
			i++
			continue
		case '\b':
			x = maxInt(0, x-1)
			i++
			continue
		case '\t':
			x = minInt(width-1, (x/8+1)*8)
			i++
			continue
		}
		if raw[i] < 0x20 || raw[i] == 0x7f {
			i++
			continue
		}
		character, size := utf8.DecodeRune(raw[i:])
		if size == 0 {
			break
		}
		if x >= width {
			x = 0
			newline()
		}
		screen[y][x] = character
		x++
		i += size
	}
	rows := make([]string, height)
	for index, row := range screen {
		rows[index] = strings.TrimRight(string(row), " ")
	}
	return strings.Join(rows, "\n")
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}

func (d *desktop) pollExit() {
	if d.exited {
		return
	}
	select {
	case d.waitErr = <-d.finished:
		d.exited = true
	default:
	}
}

func (d *desktop) waitFor(after int, expected string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		raw := d.output.snapshot()
		if after < 0 || after > len(raw) {
			after = 0
		}
		if len(raw) > after && strings.Contains(terminalText(raw), expected) {
			return nil
		}
		d.pollExit()
		if d.exited {
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	raw := d.output.snapshot()
	if after < 0 || after > len(raw) {
		after = 0
	}
	text := terminalText(raw)
	if len(text) > 5000 {
		text = text[len(text)-5000:]
	}
	return fmt.Errorf("%s: waiting for %q failed (exit=%v)\noutput since input:\n%s", d.mode, expected, d.waitErr, text)
}

func (d *desktop) key(value []byte, expected string) error {
	before := len(d.output.snapshot())
	if _, err := d.master.Write(value); err != nil {
		return fmt.Errorf("%s: send input: %w", d.mode, err)
	}
	if expected == "" {
		return nil
	}
	return d.waitFor(before, expected, 5*time.Second)
}

func (d *desktop) close() error {
	if !d.exited {
		select {
		case d.waitErr = <-d.finished:
			d.exited = true
		case <-time.After(3 * time.Second):
			if d.cmd.Process != nil {
				_ = syscall.Kill(-d.cmd.Process.Pid, syscall.SIGKILL)
			}
			d.cancel()
			<-d.finished
			d.exited = true
			_ = d.master.Close()
			<-d.readDone
			_ = os.RemoveAll(d.root)
			return fmt.Errorf("%s: process did not stop after Ctrl+Q", d.mode)
		}
	}
	_ = d.master.Close()
	<-d.readDone
	d.cancel()
	_ = os.RemoveAll(d.root)
	if err := d.waitErr; err != nil {
		return fmt.Errorf("%s: process exited with %w\n%s", d.mode, err, string(d.output.snapshot()))
	}
	return nil
}

func databaseEnvironment(root string) []string {
	names := []string{"workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance", "sync"}
	env := []string{"TERM=xterm-256color"}
	for _, name := range names {
		env = append(env, "BEE_"+strings.ToUpper(name)+"_DB="+filepath.Join(root, name+".db"))
	}
	return env
}

func startDesktop(runtime, project, pack, mode string) (*desktop, error) {
	root, err := os.MkdirTemp("", "bee-modules-"+mode+"-")
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(root, ".wippy"), 0700); err != nil {
		return nil, err
	}
	args := []string{"run"}
	if pack != "" {
		args = append(args, pack)
	}
	args = append(args, "bee", "bee.modules:app", "--host", "bee:terminal", "--set", "registry.history_path="+filepath.Join(root, "registry.db"))
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	cmd := exec.CommandContext(ctx, runtime, args...)
	cmd.Dir = project
	if pack != "" {
		cmd.Dir = root
	}
	cmd.Env = append(os.Environ(), databaseEnvironment(root)...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 3 * time.Second
	masterFD, err := syscall.Open("/dev/ptmx", syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("open PTY master: %w", err)
	}
	master := os.NewFile(uintptr(masterFD), "bee-modules-pty-master")
	unlock := int32(0)
	if err := ptyIoctl(master.Fd(), 0x40045431, uintptr(unsafe.Pointer(&unlock))); err != nil {
		_ = master.Close()
		cancel()
		return nil, fmt.Errorf("unlock PTY: %w", err)
	}
	var ptyNumber uint32
	if err := ptyIoctl(master.Fd(), 0x80045430, uintptr(unsafe.Pointer(&ptyNumber))); err != nil {
		_ = master.Close()
		cancel()
		return nil, fmt.Errorf("get PTY number: %w", err)
	}
	slaveFD, err := syscall.Open(fmt.Sprintf("/dev/pts/%d", ptyNumber), syscall.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		_ = master.Close()
		cancel()
		return nil, fmt.Errorf("open PTY slave: %w", err)
	}
	slave := os.NewFile(uintptr(slaveFD), "bee-modules-pty-slave")
	window := struct{ Rows, Cols, Xpixel, Ypixel uint16 }{Rows: 30, Cols: 100}
	if err := ptyIoctl(master.Fd(), 0x5414, uintptr(unsafe.Pointer(&window))); err != nil {
		_ = slave.Close()
		_ = master.Close()
		cancel()
		return nil, fmt.Errorf("size PTY: %w", err)
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	d := &desktop{cmd: cmd, master: master, finished: make(chan error, 1), readDone: make(chan struct{}), cancel: cancel, root: root, mode: mode}
	if err := cmd.Start(); err != nil {
		_ = slave.Close()
		_ = master.Close()
		cancel()
		return nil, fmt.Errorf("start %s PTY: %w", mode, err)
	}
	_ = slave.Close()
	go func() {
		defer close(d.readDone)
		_, _ = io.Copy(&d.output, master)
	}()
	go func() { d.finished <- cmd.Wait() }()
	return d, nil
}

func ptyIoctl(fd uintptr, request uintptr, value uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, request, value)
	if errno != 0 {
		return errno
	}
	return nil
}

func exercise(runtime, project, pack, mode string) (err error) {
	ui, err := startDesktop(runtime, project, pack, mode)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := ui.close(); err == nil && closeErr != nil {
			err = closeErr
		}
	}()
	if err = ui.waitFor(0, "MODULES", 20*time.Second); err != nil {
		return err
	}
	if err = ui.waitFor(0, "Preview fixture", 10*time.Second); err != nil {
		return err
	}
	if err = ui.waitFor(0, "Keyword: bee", 5*time.Second); err != nil {
		return err
	}
	if err = ui.key([]byte("K"), "Keyword: bee"); err != nil {
		return err
	}
	if err = ui.key([]byte("\x7f\x7f\x7f\r"), "Keyword: all"); err != nil {
		return err
	}
	if err = ui.key([]byte("/"), "Search: "); err != nil {
		return err
	}
	if err = ui.key([]byte("terminal café"), "Edit: terminal café"); err != nil {
		return err
	}
	if err = ui.key([]byte("\x7f\r"), "Search: terminal caf"); err != nil {
		return err
	}
	if err = ui.key([]byte("\x1b[B"), "Search: terminal caf"); err != nil {
		return err
	}
	if err = ui.key([]byte("\r"), "Packaged module"); err != nil {
		return err
	}
	if err = ui.waitFor(0, "1.0.0", 5*time.Second); err != nil {
		return err
	}
	if err = ui.key([]byte("h"), "Fixture guide"); err != nil {
		return err
	}
	if err = ui.waitFor(0, "Read this before installing.", 5*time.Second); err != nil {
		return err
	}
	if err = ui.key([]byte("v"), "1.0.0"); err != nil {
		return err
	}
	if err = ui.key([]byte("j"), "Parameter name (namespace:name)"); err != nil {
		return err
	}
	if err = ui.key([]byte("example:settings\r"), "Parameter JSON value"); err != nil {
		return err
	}
	if err = ui.key([]byte(`{"enabled": true, "title": "two words"}`+"\r"), "Parameter saved"); err != nil {
		return err
	}
	if err = ui.key([]byte("j"), "Parameter name (namespace:name)"); err != nil {
		return err
	}
	if err = ui.key([]byte("\x1b"), "Cancelled"); err != nil {
		return err
	}
	if err = ui.key([]byte("p"), "Ready for confirmation"); err != nil {
		return err
	}
	if strings.Contains(mustFrame(ui), "Fixture confirmation received") {
		return fmt.Errorf("%s: preparing a plan applied it", mode)
	}
	if err = ui.key(bytes.Repeat([]byte("\x1b[B"), 20), "fixture:last"); err != nil {
		return err
	}
	if err = ui.key([]byte("\r"), "MODULES  CONFIRM"); err != nil {
		return err
	}
	if err = ui.key([]byte("\x1b"), "MODULES  PLAN"); err != nil {
		return err
	}
	if strings.Contains(mustFrame(ui), "Fixture confirmation received") {
		return fmt.Errorf("%s: cancelling confirmation applied it", mode)
	}
	if err = ui.key([]byte("\r"), "MODULES  CONFIRM"); err != nil {
		return err
	}
	if err = ui.key([]byte("\r"), "Fixture confirmation received"); err != nil {
		return err
	}
	frame := mustFrame(ui)
	if !strings.Contains(frame, "Receipt state: complete") {
		return fmt.Errorf("%s: completed reply omitted receipt state\n%s", mode, frame)
	}
	if err = ui.key([]byte("\x11"), ""); err != nil {
		return err
	}
	return nil
}

func mustFrame(ui *desktop) string {
	return terminalText(ui.output.snapshot())
}

func run() error {
	runtime := os.Getenv("BEE_RUNTIME")
	if runtime == "" {
		runtime = ".wippy/bin/bee-wippy"
	}
	runtime, err := filepath.Abs(runtime)
	if err != nil {
		return err
	}
	project, err := os.MkdirTemp("", "bee-modules-project-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(project)
	if err := os.CopyFS(filepath.Join(project, "src"), os.DirFS("src")); err != nil {
		return fmt.Errorf("copy source tree: %w", err)
	}
	for _, name := range []string{".wippy.yaml", "wippy.lock", "wippy.yaml"} {
		if err := copyFile(name, filepath.Join(project, name)); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(filepath.Join(project, ".wippy"), 0700); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(project, "src/hub/facade.lua"), []byte(fixtureFacade), 0600); err != nil {
		return fmt.Errorf("write fixture facade: %w", err)
	}
	pack := filepath.Join(project, "modules-test.wapp")
	packCtx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	packCmd := exec.CommandContext(packCtx, runtime, "pack", pack)
	packCmd.Dir = project
	if output, err := packCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("build fixture pack: %w\n%s", err, output)
	}
	if err := exercise(runtime, project, "", "source"); err != nil {
		return err
	}
	if err := exercise(runtime, project, pack, "pack"); err != nil {
		return err
	}
	fmt.Println("Modules source/pack: catalog filters, details, README, typed JSON input, plan review/cancel/confirm and completed receipt pass")
	return nil
}

func copyFile(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("read %s: %w", source, err)
	}
	if err := os.WriteFile(destination, data, 0600); err != nil {
		return fmt.Errorf("write %s: %w", destination, err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
