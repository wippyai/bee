// SPDX-License-Identifier: MIT
// Acceptance harness proving Bee host admission and remote Native Terminal mounts across two native runtimes.
package main

import (
	"archive/tar"
	"bufio"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed fixtures/hive_remote/*
var fixture embed.FS

type safeBuffer struct {
	sync.Mutex
	buf       []byte
	maxBytes  int
	truncated bool
}

func newSafeBuffer(maxBytes int) *safeBuffer {
	if maxBytes <= 0 {
		maxBytes = 64 * 1024
	}
	return &safeBuffer{
		maxBytes: maxBytes,
		buf:      make([]byte, 0, min(maxBytes, 4096)),
	}
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	n := len(p)
	if n == 0 {
		return 0, nil
	}
	if b.maxBytes <= 0 {
		b.maxBytes = 64 * 1024
	}
	if n >= b.maxBytes {
		b.truncated = b.truncated || len(b.buf) > 0 || n > b.maxBytes
		b.buf = append(b.buf[:0], p[n-b.maxBytes:]...)
		return n, nil
	}
	if len(b.buf)+n > b.maxBytes {
		excess := (len(b.buf) + n) - b.maxBytes
		copy(b.buf, b.buf[excess:])
		b.buf = b.buf[:len(b.buf)-excess]
		b.truncated = true
	}
	b.buf = append(b.buf, p...)
	return n, nil
}

func (b *safeBuffer) String() string {
	b.Lock()
	defer b.Unlock()
	if b.truncated {
		return "[... resident log truncated ...]\n" + string(b.buf)
	}
	return string(b.buf)
}

func (b *safeBuffer) Len() int {
	b.Lock()
	defer b.Unlock()
	return len(b.buf)
}

func (b *safeBuffer) Truncated() bool {
	b.Lock()
	defer b.Unlock()
	return b.truncated
}

type outputCollector struct {
	lines      chan string
	stderr     *safeBuffer
	scanErr    error
	wg         sync.WaitGroup
	stdoutPipe io.ReadCloser
}

func startReader(ctx context.Context, r io.ReadCloser, nodeName string, stderr *safeBuffer) *outputCollector {
	c := &outputCollector{
		lines:      make(chan string, 100),
		stderr:     stderr,
		stdoutPipe: r,
	}
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		defer close(c.lines)
		scanner := bufio.NewScanner(r)
		for scanner.Scan() {
			line := scanner.Text()
			prefix := "BEE_HIVE_REMOTE "
			_, marker, ok := strings.Cut(line, prefix)
			if !ok {
				prefix = "BEE_HIVE_SUPERVISOR "
				_, marker, ok = strings.Cut(line, prefix)
			}
			if !ok {
				prefix = "BEE_HIVE_SERVICE "
				_, marker, ok = strings.Cut(line, prefix)
			}
			if ok {
				fmt.Printf("%s %s: %s\n", time.Now().Format(time.RFC3339), nodeName, marker)
				select {
				case c.lines <- prefix + marker:
				case <-ctx.Done():
					return
				}
			} else {
				_, _ = c.stderr.Write([]byte(line + "\n"))
			}
		}
		if err := scanner.Err(); err != nil && err != io.EOF {
			c.scanErr = err
			_, _ = c.stderr.Write([]byte(fmt.Sprintf("%s scanner error: %v\n", nodeName, err)))
		}
	}()
	return c
}

func (c *outputCollector) waitReader(timeout time.Duration) bool {
	done := make(chan struct{})
	go func() {
		c.wg.Wait()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-time.After(timeout):
		if c.stdoutPipe != nil {
			_ = c.stdoutPipe.Close()
		}
		return false
	}
}

type procRunner struct {
	cmd       *exec.Cmd
	collector *outputCollector
	stdin     io.WriteCloser
	stdout    io.ReadCloser
	stderr    *safeBuffer
	waitOnce  sync.Once
	waitErr   error
	waitDone  chan struct{}
	killed    bool
}

func newProcRunner(cmd *exec.Cmd, name string) (*procRunner, error) {
	cmd.WaitDelay = 3 * time.Second

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("%s stdin: %w", name, err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("%s stdout: %w", name, err)
	}
	stderr := newSafeBuffer(64 * 1024)
	cmd.Stderr = stderr

	return &procRunner{
		cmd:      cmd,
		stdin:    stdin,
		stdout:   stdout,
		stderr:   stderr,
		waitDone: make(chan struct{}),
	}, nil
}

func (r *procRunner) start(ctx context.Context, name string) error {
	if err := r.cmd.Start(); err != nil {
		return fmt.Errorf("%s start: %w", name, err)
	}
	r.collector = startReader(ctx, r.stdout, name, r.stderr)
	return nil
}

func (r *procRunner) wait(timeout time.Duration) error {
	if r == nil || r.cmd == nil || r.cmd.Process == nil {
		return nil
	}
	if r.collector != nil {
		if !r.collector.waitReader(timeout) {
			if r.stdout != nil {
				_ = r.stdout.Close()
			}
		}
	}
	r.waitOnce.Do(func() {
		go func() {
			r.waitErr = r.cmd.Wait()
			close(r.waitDone)
		}()
	})
	select {
	case <-r.waitDone:
		return r.waitErr
	case <-time.After(timeout):
		r.killed = true
		if r.cmd.Process != nil {
			_ = r.cmd.Process.Kill()
		}
		if r.stdout != nil {
			_ = r.stdout.Close()
		}
		select {
		case <-r.waitDone:
			return fmt.Errorf("process wait timed out after %v and killed: %v", timeout, r.waitErr)
		case <-time.After(3 * time.Second):
			return fmt.Errorf("process wait timed out after %v and kill failed to reap", timeout)
		}
	}
}

func (r *procRunner) stop() error {
	if r == nil || r.cmd == nil || r.cmd.Process == nil {
		return nil
	}
	if r.stdin != nil {
		_ = r.stdin.Close()
	}
	if r.stdout != nil {
		_ = r.stdout.Close()
	}
	select {
	case <-r.waitDone:
		return nil
	default:
	}
	r.killed = true
	_ = r.cmd.Process.Kill()
	r.waitOnce.Do(func() {
		go func() {
			r.waitErr = r.cmd.Wait()
			close(r.waitDone)
		}()
	})
	select {
	case <-r.waitDone:
		return nil
	case <-time.After(3 * time.Second):
		return fmt.Errorf("process %d failed to reap after kill", r.cmd.Process.Pid)
	}
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func archiveDir(srcDir string, w io.Writer) (retErr error) {
	tw := tar.NewWriter(w)
	defer func() {
		if closeErr := tw.Close(); closeErr != nil && retErr == nil {
			retErr = fmt.Errorf("close tar writer: %w", closeErr)
		}
	}()

	err := filepath.Walk(srcDir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		if !info.IsDir() && !info.Mode().IsRegular() {
			return fmt.Errorf("refusing non-regular file in archive: %s (mode %v)", rel, info.Mode())
		}
		hdr, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return err
		}
		hdr.Name = filepath.ToSlash(rel)
		if info.IsDir() {
			hdr.Mode = 0700
			return tw.WriteHeader(hdr)
		}
		hdr.Mode = 0600
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(tw, f)
		closeErr := f.Close()
		if copyErr != nil {
			return copyErr
		}
		return closeErr
	})
	if err != nil {
		return err
	}
	return nil
}

func sanitizeDiagnostics(s string, secretStr string, keys []string) string {
	if secretStr != "" {
		s = strings.ReplaceAll(s, secretStr, "[REDACTED_SECRET]")
	}
	for i, k := range keys {
		if k != "" {
			s = strings.ReplaceAll(s, k, fmt.Sprintf("[REDACTED_KEY_%d]", i))
		}
	}
	return s
}

func cleanupRemoteNodeA(sshTarget, remoteDir, remoteRuntimePath string, mustHavePID bool) error {
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	mustFlag := "0"
	if mustHavePID {
		mustFlag = "1"
	}

	script := fmt.Sprintf(`
dir=%s
exe=%s
must_have_pid=%s
pidfile="$dir/host.pid"
starttimefile="$dir/host.starttime"

if [ ! -d "$dir" ]; then
    exit 0
fi

if [ "$must_have_pid" = "1" ] && { [ ! -f "$pidfile" ] || [ ! -f "$starttimefile" ]; }; then
    echo "missing process identity in $dir; preserving $dir" >&2
    exit 1
fi

if [ -f "$pidfile" ] || [ -f "$starttimefile" ]; then
    if [ ! -f "$pidfile" ] || [ ! -f "$starttimefile" ]; then
        echo "incomplete process identity in $dir; preserving $dir" >&2
        exit 1
    fi
    pid=$(cat "$pidfile" 2>/dev/null | tr -d ' \t\n\r')
    start_ticks=$(cat "$starttimefile" 2>/dev/null | tr -d ' \t\n\r')

    case "$pid" in
        ''|*[!0-9]*)
            echo "invalid pid in $pidfile: $pid; preserving $dir" >&2
            exit 1
            ;;
    esac

    case "$start_ticks" in
        ''|*[!0-9]*)
            echo "invalid starttime in $starttimefile: $start_ticks; preserving $dir" >&2
            exit 1
            ;;
    esac

    if [ -d "/proc/$pid" ]; then
        expected_exe=$(readlink -f "$exe" 2>/dev/null || echo "$exe")
        proc_exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
        if [ "$expected_exe" != "$proc_exe" ]; then
            echo "PID $pid exe mismatch: expected $expected_exe, got $proc_exe; preserving $dir" >&2
            exit 1
        fi

        expected_cwd=$(readlink -f "$dir" 2>/dev/null || echo "$dir")
        proc_cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
        if [ "$expected_cwd" != "$proc_cwd" ]; then
            echo "PID $pid cwd mismatch: expected $expected_cwd, got $proc_cwd; preserving $dir" >&2
            exit 1
        fi

        proc_ticks=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
        if [ "$proc_ticks" != "$start_ticks" ]; then
            echo "PID $pid start ticks mismatch: expected $start_ticks, got $proc_ticks; preserving $dir" >&2
            exit 1
        fi

        kill -15 "$pid" 2>/dev/null || true
        for i in $(seq 1 30); do
            if [ ! -d "/proc/$pid" ]; then break; fi
            sleep 0.1
        done
        if [ -d "/proc/$pid" ]; then
            proc_ticks=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
            if [ "$proc_ticks" != "$start_ticks" ]; then
                echo "process identity changed before force-stop; preserving $dir" >&2
                exit 1
            fi
            kill -9 "$pid" 2>/dev/null || true
            for i in $(seq 1 10); do
                if [ ! -d "/proc/$pid" ]; then break; fi
                sleep 0.1
            done
        fi
        if [ -d "/proc/$pid" ]; then
            echo "owned process $pid failed to stop; preserving $dir" >&2
            exit 1
        fi
    fi
fi
rm -rf "$dir"
`, shellQuote(remoteDir), shellQuote(remoteRuntimePath), mustFlag)

	cmd := exec.CommandContext(cleanupCtx, "ssh", "-o", "BatchMode=yes", "--", sshTarget, script)
	cmd.WaitDelay = 3 * time.Second
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("remote cleanup error on %s: %v (%s)", remoteDir, err, strings.TrimSpace(string(out)))
	}
	return nil
}

type harnessConfig struct {
	runtimePath       string
	sshTarget         string
	remoteRuntimePath string
	remoteStageParent string
	hostAddress       string
	clientAddress     string
	stallProbe        bool
	presenterStall    bool
	desktopProbe      bool
}

func parseAndValidateFlags(args []string) (*harnessConfig, error) {
	fs := flag.NewFlagSet("hive_remote", flag.ContinueOnError)
	runtimePath := fs.String("runtime", ".wippy/bin/bee-wippy-hive", "local native toolchain binary")
	sshTarget := fs.String("ssh", "", "SSH target for Node A host (e.g. wolfy-j@100.70.10.28); empty for local loopback")
	remoteRuntimePath := fs.String("remote-runtime", "", "remote native toolchain binary on SSH host (required absolute path if -ssh)")
	remoteStageParent := fs.String("remote-stage-parent", "", "remote directory parent for run staging; if empty, derived from dirname(-remote-runtime)")
	hostAddrFlag := fs.String("host-address", "", "host (node A) bind/advertise IP address (default: 127.0.0.1 for loopback; required if -ssh)")
	clientAddrFlag := fs.String("client-address", "", "client (node B) bind/advertise IP address (default: 127.0.0.1 for loopback; required if -ssh)")
	stallProbe := fs.Bool("stall", false, "pause local destination runtime to verify concurrent native viewport yields (Unix only)")
	presenterStall := fs.Bool("presenter-stall", false, "pause local destination runtime to verify production bee.terminal:main UI responsiveness (Unix only)")
	desktopProbe := fs.Bool("desktop", false, "run actual desktop client acceptance phase (Unix only)")

	if err := fs.Parse(args); err != nil {
		return nil, err
	}

	cfg := &harnessConfig{
		runtimePath:       *runtimePath,
		sshTarget:         *sshTarget,
		remoteRuntimePath: *remoteRuntimePath,
		remoteStageParent: *remoteStageParent,
		hostAddress:       *hostAddrFlag,
		clientAddress:     *clientAddrFlag,
		stallProbe:        *stallProbe,
		presenterStall:    *presenterStall,
		desktopProbe:      *desktopProbe,
	}

	if err := validateConfig(cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}

func validateConfig(cfg *harnessConfig) error {
	probeCount := 0
	if cfg.stallProbe {
		probeCount++
	}
	if cfg.presenterStall {
		probeCount++
	}
	if cfg.desktopProbe {
		probeCount++
	}
	if probeCount > 1 {
		return fmt.Errorf("-stall, -presenter-stall, and -desktop cannot be combined")
	}
	if cfg.presenterStall && (cfg.sshTarget != "" || runtime.GOOS == "windows") {
		return fmt.Errorf("-presenter-stall requires two locally launched runtimes on Unix")
	}
	if cfg.stallProbe && (cfg.sshTarget != "" || runtime.GOOS == "windows") {
		return fmt.Errorf("-stall requires two locally launched runtimes on Unix")
	}
	if cfg.desktopProbe && runtime.GOOS == "windows" {
		return fmt.Errorf("-desktop requires Unix")
	}
	if cfg.runtimePath == "" {
		return fmt.Errorf("-runtime is required")
	}
	binary, err := filepath.Abs(cfg.runtimePath)
	if err != nil {
		return fmt.Errorf("runtime path: %w", err)
	}
	if _, err := os.Stat(binary); err != nil {
		return fmt.Errorf("runtime binary not found at %s: %w", binary, err)
	}
	cfg.runtimePath = binary

	if cfg.sshTarget == "" {
		if cfg.hostAddress == "" {
			cfg.hostAddress = "127.0.0.1"
		}
		if cfg.clientAddress == "" {
			cfg.clientAddress = "127.0.0.1"
		}
		if net.ParseIP(cfg.hostAddress) == nil {
			return fmt.Errorf("invalid host IP address: %q", cfg.hostAddress)
		}
		if net.ParseIP(cfg.clientAddress) == nil {
			return fmt.Errorf("invalid client IP address: %q", cfg.clientAddress)
		}
		return nil
	}

	if strings.HasPrefix(cfg.sshTarget, "-") {
		return fmt.Errorf("ssh target cannot begin with '-': %q", cfg.sshTarget)
	}
	for _, ch := range cfg.sshTarget {
		if !((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '@' || ch == '.' || ch == '-' || ch == '_') {
			return fmt.Errorf("invalid characters in ssh target: %q", cfg.sshTarget)
		}
	}

	if cfg.remoteRuntimePath == "" {
		return fmt.Errorf("-remote-runtime is required when -ssh is specified")
	}
	if !filepath.IsAbs(cfg.remoteRuntimePath) {
		return fmt.Errorf("-remote-runtime must be an absolute path, got: %q", cfg.remoteRuntimePath)
	}

	if cfg.hostAddress == "" {
		return fmt.Errorf("-host-address is required when -ssh is specified")
	}
	if cfg.clientAddress == "" {
		return fmt.Errorf("-client-address is required when -ssh is specified")
	}
	if net.ParseIP(cfg.hostAddress) == nil {
		return fmt.Errorf("invalid host IP address: %q", cfg.hostAddress)
	}
	if net.ParseIP(cfg.clientAddress) == nil {
		return fmt.Errorf("invalid client IP address: %q", cfg.clientAddress)
	}

	if cfg.remoteStageParent == "" {
		cfg.remoteStageParent = filepath.Dir(cfg.remoteRuntimePath)
	}
	if !filepath.IsAbs(cfg.remoteStageParent) || cfg.remoteStageParent == "/" || cfg.remoteStageParent == "." {
		return fmt.Errorf("remote stage parent must be an absolute directory, got: %q", cfg.remoteStageParent)
	}

	return nil
}

func run() (retErr error) {
	cfg, err := parseAndValidateFlags(os.Args[1:])
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	if cfg.sshTarget != "" {
		checkCmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", cfg.sshTarget,
			fmt.Sprintf("test -x %s", shellQuote(cfg.remoteRuntimePath)))
		checkCmd.WaitDelay = 3 * time.Second
		if out, err := checkCmd.CombinedOutput(); err != nil {
			return fmt.Errorf("remote runtime %s is not executable or accessible: %v (%s)", cfg.remoteRuntimePath, err, strings.TrimSpace(string(out)))
		}
	}

	root, err := os.MkdirTemp("", "bee-hive-remote-")
	if err != nil {
		return fmt.Errorf("temp root: %w", err)
	}

	var remoteFolderA string
	var remoteFolderCreated bool
	var cmdAStarted bool
	if cfg.sshTarget != "" {
		var randBytes [8]byte
		if _, err := rand.Read(randBytes[:]); err != nil {
			_ = os.RemoveAll(root)
			return fmt.Errorf("rand remote id: %w", err)
		}
		remoteFolderA = filepath.Join(cfg.remoteStageParent, fmt.Sprintf("run-%x", randBytes))
	}

	var (
		runnerA *procRunner
		runnerB *procRunner
	)

	cleanup := func() (errs []error) {
		if runnerB != nil {
			if err := runnerB.stop(); err != nil {
				errs = append(errs, fmt.Errorf("stop node B: %w", err))
			}
		}
		if runnerA != nil {
			if err := runnerA.stop(); err != nil {
				errs = append(errs, fmt.Errorf("stop node A: %w", err))
			}
		}
		if cfg.sshTarget != "" && remoteFolderCreated && remoteFolderA != "" {
			if err := cleanupRemoteNodeA(cfg.sshTarget, remoteFolderA, cfg.remoteRuntimePath, cmdAStarted); err != nil {
				errs = append(errs, fmt.Errorf("remote node A cleanup: %w", err))
			}
		}
		if root != "" && len(errs) == 0 {
			if err := os.RemoveAll(root); err != nil {
				errs = append(errs, fmt.Errorf("remove temp root: %w", err))
			}
		} else if len(errs) > 0 {
			errs = append(errs, fmt.Errorf("preserved local diagnostics at %s", root))
		}
		return errs
	}

	defer func() {
		cleanupErrs := cleanup()
		if len(cleanupErrs) > 0 {
			var combined []error
			if retErr != nil {
				combined = append(combined, retErr)
			}
			for _, cErr := range cleanupErrs {
				combined = append(combined, cErr)
			}
			retErr = errors.Join(combined...)
		}
	}()

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return fmt.Errorf("rand secret: %w", err)
	}
	secretStr := base64.StdEncoding.EncodeToString(secret)

	keys := make([]string, 2)
	trusted := make(map[string]string, 2)
	for i := 0; i < 2; i++ {
		pub, key, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return fmt.Errorf("ed25519 key %d: %w", i, err)
		}
		keys[i] = base64.RawStdEncoding.EncodeToString(key)
		trusted[fmt.Sprintf("node-%d", i)] = base64.RawStdEncoding.EncodeToString(pub)
	}

	writeNodeFiles := func(i int, stagingFolder, targetFolder, seed, bindIP string) error {
		srcDir := filepath.Join(stagingFolder, "src")
		if err := os.CopyFS(srcDir, os.DirFS("src")); err != nil {
			return fmt.Errorf("copy src: %w", err)
		}
		if cfg.desktopProbe {
			// Instrument only the disposable copy: distinguish a newly attached
			// presenter from the physical display's retained previous frame.
			path := filepath.Join(srcDir, "core", "terminal", "main.lua")
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			const label = `"Workspace " .. names.label(workspace_id)`
			if strings.Count(string(data), label) != 1 {
				return fmt.Errorf("desktop presenter probe: expected one label anchor")
			}
			data = []byte(strings.Replace(string(data), label, label+` .. " " .. tostring(process.pid()):sub(-12)`, 1))
			if err := os.WriteFile(path, data, 0600); err != nil {
				return err
			}
		}

		fixtureDir := filepath.Join(srcDir, "hive_remote")
		if err := os.MkdirAll(fixtureDir, 0700); err != nil {
			return fmt.Errorf("mkdir fixture dir: %w", err)
		}
		for _, name := range []string{"_index.yaml", "host.lua", "client.lua"} {
			data, err := fixture.ReadFile("fixtures/hive_remote/" + name)
			if err != nil {
				return fmt.Errorf("read embedded fixture %s: %w", name, err)
			}
			if err := os.WriteFile(filepath.Join(fixtureDir, name), data, 0600); err != nil {
				return fmt.Errorf("write fixture %s: %w", name, err)
			}
		}

		if err := os.WriteFile(filepath.Join(stagingFolder, "wippy.lock"), []byte("directories:\n  modules: .wippy\n  src: ./src\n"), 0600); err != nil {
			return fmt.Errorf("write wippy.lock: %w", err)
		}

		role := "client"
		expect := 0
		if i == 0 {
			role = "server"
			expect = 1
		}

		config := map[string]any{
			"version":  "1.0",
			"shutdown": map[string]any{"timeout": "2s"},
			"relay":    map[string]any{"node_name": fmt.Sprintf("node-%d", i)},
			"lua": map[string]any{
				"type_system": map[string]any{"enabled": true, "strict": true},
			},
			"cluster": map[string]any{
				"enabled": true,
				"name":    fmt.Sprintf("node-%d", i),
				"raft": map[string]any{
					"role":             role,
					"bootstrap_expect": expect,
					"max_voters":       1,
					"max_standbys":     0,
					"data_dir":         filepath.Join(targetFolder, "node-state"),
				},
				"membership": map[string]any{
					"bind_addr":  bindIP,
					"bind_port":  0,
					"join_addrs": seed,
					"secret_key": secretStr,
				},
				"internode": map[string]any{
					"bind_addr":         bindIP,
					"bind_port":         0,
					"auto_port":         true,
					"identity_key":      keys[i],
					"trusted_peer_keys": trusted,
				},
			},
		}

		cfgData, err := json.Marshal(config)
		if err != nil {
			return fmt.Errorf("marshal config: %w", err)
		}
		return os.WriteFile(filepath.Join(stagingFolder, ".wippy.yaml"), cfgData, 0600)
	}

	folderA := filepath.Join(root, "node-0")
	targetFolderA := folderA
	if cfg.sshTarget != "" {
		targetFolderA = remoteFolderA
	}

	if err := writeNodeFiles(0, folderA, targetFolderA, "", cfg.hostAddress); err != nil {
		return fmt.Errorf("node A setup: %w", err)
	}

	destBytes := make([]byte, 16)
	if _, err := rand.Read(destBytes); err != nil {
		return fmt.Errorf("rand destToken: %w", err)
	}
	destToken := fmt.Sprintf("proof_%x", destBytes)
	proofFileName := "node_a_dest_proof.token"
	if err := os.WriteFile(filepath.Join(folderA, proofFileName), []byte(destToken+"\n"), 0600); err != nil {
		return fmt.Errorf("write destination proof file on node A: %w", err)
	}

	if cfg.sshTarget != "" {
		createCmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", cfg.sshTarget,
			"mkdir -m 0700 -- "+shellQuote(remoteFolderA))
		createCmd.WaitDelay = 3 * time.Second
		if out, err := createCmd.CombinedOutput(); err != nil {
			return fmt.Errorf("create remote stage: %w (%s)", err, strings.TrimSpace(string(out)))
		}
		remoteFolderCreated = true
		transferCmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", cfg.sshTarget,
			"tar -xf - -C "+shellQuote(remoteFolderA))
		transferCmd.WaitDelay = 3 * time.Second
		transferStdin, err := transferCmd.StdinPipe()
		if err != nil {
			return fmt.Errorf("remote stage stdin: %w", err)
		}
		transferErrBuf := newSafeBuffer(64 * 1024)
		transferCmd.Stderr = transferErrBuf

		if err := transferCmd.Start(); err != nil {
			return fmt.Errorf("start remote staging: %w", err)
		}

		tarErr := archiveDir(folderA, transferStdin)
		closeErr := transferStdin.Close()
		waitErr := transferCmd.Wait()
		if tarErr != nil {
			return fmt.Errorf("tar stage: %w", tarErr)
		}
		if closeErr != nil {
			return fmt.Errorf("close stage stdin: %w", closeErr)
		}
		if waitErr != nil {
			return fmt.Errorf("remote unpack stage failed: %v (%s)", waitErr, strings.TrimSpace(transferErrBuf.String()))
		}
	}

	folderB := filepath.Join(root, "node-1")

	var cmdA *exec.Cmd
	if cfg.sshTarget == "" {
		cmdA = exec.CommandContext(ctx, cfg.runtimePath, "run", "--verbose", "hive-remote-host")
		cmdA.Dir = folderA
		cmdA.Env = append(os.Environ(),
			"GOMAXPROCS=2",
			"BEE_WORKSPACE_DB="+filepath.Join(folderA, "workspace.db"),
			"BEE_THREADS_DB="+filepath.Join(folderA, "threads.db"),
		)
	} else {
		remoteCmd := fmt.Sprintf("cd %s && echo $$ > host.pid && sed 's/^.*) //' /proc/$$/stat | awk '{print $20}' > host.starttime && exec env GOMAXPROCS=2 BEE_WORKSPACE_DB=%s/workspace.db BEE_THREADS_DB=%s/threads.db %s run --verbose hive-remote-host",
			shellQuote(remoteFolderA),
			shellQuote(remoteFolderA),
			shellQuote(remoteFolderA),
			shellQuote(cfg.remoteRuntimePath),
		)
		cmdA = exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", cfg.sshTarget, remoteCmd)
	}

	var errA error
	runnerA, errA = newProcRunner(cmdA, "node A")
	if errA != nil {
		return errA
	}
	if err := runnerA.start(ctx, "node A"); err != nil {
		return err
	}
	cmdAStarted = true

	waitMarker := func(collector *outputCollector, nodeName, stage, prefix string) (string, error) {
		for {
			select {
			case line, ok := <-collector.lines:
				if !ok {
					errMsg := fmt.Sprintf("[%s] %s closed output while waiting for %q", stage, nodeName, prefix)
					if collector.scanErr != nil {
						errMsg += fmt.Sprintf(" (scanner error: %v)", collector.scanErr)
					}
					return "", fmt.Errorf("%s\n%s stderr:\n%s", errMsg, nodeName, sanitizeDiagnostics(collector.stderr.String(), secretStr, keys))
				}
				if strings.HasPrefix(line, prefix) {
					return line, nil
				}
			case <-ctx.Done():
				return "", fmt.Errorf("[%s] timeout waiting for %q from %s: %w\n%s stderr:\n%s",
					stage, prefix, nodeName, ctx.Err(), nodeName, sanitizeDiagnostics(collector.stderr.String(), secretStr, keys))
			}
		}
	}

	readyLine, err := waitMarker(runnerA.collector, "node A", "host startup", "BEE_HIVE_REMOTE host_ready ")
	if err != nil {
		return err
	}

	fields := strings.Fields(readyLine)
	if len(fields) != 6 {
		return fmt.Errorf("unexpected host_ready format: %q", readyLine)
	}
	seedAddr := fields[2]
	supervisorPID := fields[3]
	hostPID := fields[4]
	workspaceID := fields[5]

	if err := writeNodeFiles(1, folderB, folderB, seedAddr, cfg.clientAddress); err != nil {
		return fmt.Errorf("node B setup: %w", err)
	}

	if _, err := os.Stat(filepath.Join(folderB, proofFileName)); !os.IsNotExist(err) {
		return fmt.Errorf("node B must not contain destination proof file %s", proofFileName)
	}

	cmdB := exec.CommandContext(ctx, cfg.runtimePath, "run", "--silent", "hive-remote-client", "--",
		hostPID, workspaceID, supervisorPID, destToken, proofFileName,
		strconv.FormatBool(cfg.stallProbe), strconv.FormatBool(cfg.presenterStall), strconv.FormatBool(cfg.desktopProbe))
	cmdB.Dir = folderB
	cmdB.Env = append(os.Environ(),
		"GOMAXPROCS=2",
		"BEE_WORKSPACE_DB="+filepath.Join(folderB, "workspace.db"),
		"BEE_THREADS_DB="+filepath.Join(folderB, "threads.db"),
	)

	runnerB, err = newProcRunner(cmdB, "node B")
	if err != nil {
		return err
	}
	if err := runnerB.start(ctx, "node B"); err != nil {
		return err
	}

	clientLine, err := waitMarker(runnerB.collector, "node B", "client startup", "BEE_HIVE_REMOTE client_ready ")
	if err != nil {
		return err
	}
	clientFields := strings.Fields(clientLine)
	if len(clientFields) != 3 {
		return fmt.Errorf("unexpected client_ready format: %q", clientLine)
	}
	clientPID := clientFields[2]

	if cfg.desktopProbe {
		if _, err := io.WriteString(runnerA.stdin, fmt.Sprintf("desktop %s\n", clientPID)); err != nil {
			return fmt.Errorf("send desktop command to supervisor: %w", err)
		}
		if _, err := waitMarker(runnerA.collector, "node A", "supervisor desktop ready", "BEE_HIVE_REMOTE desktop_ready "+clientPID); err != nil {
			return fmt.Errorf("supervisor desktop ready: %w", err)
		}
		if _, err := waitMarker(runnerB.collector, "node B", "desktop client acceptance", "BEE_HIVE_REMOTE client_passed"); err != nil {
			return fmt.Errorf("desktop client acceptance: %w\nnode A stderr:\n%s", err, sanitizeDiagnostics(runnerA.stderr.String(), secretStr, keys))
		}
		if _, err := io.WriteString(runnerA.stdin, "shutdown\n"); err != nil {
			return fmt.Errorf("send shutdown to supervisor: %w", err)
		}
		if _, err := waitMarker(runnerA.collector, "node A", "supervisor shutdown", "BEE_HIVE_REMOTE supervisor_done"); err != nil {
			return fmt.Errorf("supervisor shutdown: %w", err)
		}
	} else {
		// Step 1: Supervisor on Node A admits client B
		if _, err := io.WriteString(runnerA.stdin, fmt.Sprintf("admit %s\n", clientPID)); err != nil {
			return fmt.Errorf("send admit command to supervisor: %w", err)
		}
		if _, err := waitMarker(runnerA.collector, "node A", "supervisor admission", "BEE_HIVE_REMOTE admitted "+clientPID); err != nil {
			return fmt.Errorf("supervisor admission result: %w", err)
		}

		if cfg.stallProbe {
			if _, err := waitMarker(runnerB.collector, "node B", "mounted", "BEE_HIVE_REMOTE mounted"); err != nil {
				return err
			}
			signalHost := func(signal string) error {
				return exec.CommandContext(ctx, "kill", signal, strconv.Itoa(cmdA.Process.Pid)).Run()
			}
			if err := signalHost("-STOP"); err != nil {
				return err
			}
			if _, err := io.WriteString(runnerB.stdin, "paused\n"); err != nil {
				return err
			}
			if _, err := waitMarker(runnerB.collector, "node B", "responsive during stopped host", "BEE_HIVE_REMOTE responsive"); err != nil {
				return err // Deferred cleanup kills the owned stopped process on failure.
			}
			if err := signalHost("-CONT"); err != nil {
				return err
			}
		} else if cfg.presenterStall {
			if _, err := waitMarker(runnerB.collector, "node B", "presenter mounted", "BEE_HIVE_REMOTE presenter_mounted"); err != nil {
				return err
			}
			signalHost := func(signal string) error {
				return exec.CommandContext(ctx, "kill", signal, strconv.Itoa(cmdA.Process.Pid)).Run()
			}
			if err := signalHost("-STOP"); err != nil {
				return err
			}
			if _, err := io.WriteString(runnerB.stdin, "paused\n"); err != nil {
				return err
			}
			if _, err := waitMarker(runnerB.collector, "node B", "presenter responsive during stopped host", "BEE_HIVE_REMOTE presenter_responsive"); err != nil {
				return err // Deferred cleanup kills the owned stopped process on failure.
			}
			if err := signalHost("-CONT"); err != nil {
				return err
			}
			if _, err := io.WriteString(runnerB.stdin, "resumed\n"); err != nil {
				return err
			}
		}
		// Step 2: Client B performs active operations
		if _, err := waitMarker(runnerB.collector, "node B", "client active operations", "BEE_HIVE_REMOTE client_active_done"); err != nil {
			return fmt.Errorf("client active tests: %w\nnode A stderr:\n%s", err, sanitizeDiagnostics(runnerA.stderr.String(), secretStr, keys))
		}

		// Step 3: Supervisor on Node A detaches client B
		if _, err := io.WriteString(runnerA.stdin, fmt.Sprintf("detach %s\n", clientPID)); err != nil {
			return fmt.Errorf("send detach command to supervisor: %w", err)
		}
		if _, err := waitMarker(runnerA.collector, "node A", "supervisor detach", "BEE_HIVE_REMOTE detached "+clientPID); err != nil {
			return fmt.Errorf("supervisor detach result: %w", err)
		}

		// Step 4: Instruct Client B to verify stale / revoked control
		if _, err := io.WriteString(runnerB.stdin, "verify_stale\n"); err != nil {
			return fmt.Errorf("send verify_stale to client: %w", err)
		}
		if _, err := waitMarker(runnerB.collector, "node B", "client stale control", "BEE_HIVE_REMOTE client_stale_done"); err != nil {
			return fmt.Errorf("client stale control verification: %w", err)
		}
		if _, err := io.WriteString(runnerA.stdin, fmt.Sprintf("admit %s\n", clientPID)); err != nil {
			return err
		}
		if _, err := waitMarker(runnerA.collector, "node A", "supervisor re-admission", "BEE_HIVE_REMOTE admitted "+clientPID); err != nil {
			return err
		}
		if _, err := waitMarker(runnerB.collector, "node B", "client re-admission & persist", "BEE_HIVE_REMOTE client_passed"); err != nil {
			return err
		}

		// Step 5: Clean supervisor shutdown
		if _, err := io.WriteString(runnerA.stdin, "shutdown\n"); err != nil {
			return fmt.Errorf("send shutdown to supervisor: %w", err)
		}
		if _, err := waitMarker(runnerA.collector, "node A", "supervisor shutdown", "BEE_HIVE_REMOTE supervisor_done"); err != nil {
			return fmt.Errorf("supervisor shutdown: %w", err)
		}
	}

	waitErrB := runnerB.wait(5 * time.Second)
	waitErrA := runnerA.wait(5 * time.Second)

	if waitErrB != nil {
		return fmt.Errorf("node B exit error: %v, stderr: %s", waitErrB, sanitizeDiagnostics(runnerB.stderr.String(), secretStr, keys))
	}
	if waitErrA != nil {
		return fmt.Errorf("node A exit error: %v, stderr: %s", waitErrA, sanitizeDiagnostics(runnerA.stderr.String(), secretStr, keys))
	}

	if cfg.desktopProbe {
		fmt.Printf("Hive remote (desktop): 2 independent native runtimes, actual bee.client:main desktop client, native display viewport, destination bash proof, stty resize, F12 rejoin, detach & reattach to retained terminal verified successfully\n")
	} else if cfg.sshTarget != "" {
		fmt.Printf("Hive remote (LAN SSH Node A %s, local Node B %s): 2 independent native runtimes, supervisor admission, remote Native Terminal mount, process proof, stty resize, and revoked control verified successfully\n", cfg.hostAddress, cfg.clientAddress)
	} else if cfg.presenterStall {
		fmt.Printf("Hive remote (presenter-stall): 2 independent native runtimes, supervisor admission, real bee.terminal:main presenter responsive during paused host, F1 menu, F12 retire, shell PID & variable preserved across re-admission verified successfully\n")
	} else {
		fmt.Printf("Hive remote: 2 independent native runtimes, supervisor admission, remote Native Terminal mount, process proof, stty resize, and revoked control verified successfully\n")
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "HIVE REMOTE FAILED:", err)
		os.Exit(1)
	}
}
