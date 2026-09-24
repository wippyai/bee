// SPDX-License-Identifier: MIT
package main

import (
	"context"
	"crypto/rand"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The optional SSH path stages an owner on another machine. It does not enroll
// production peers or modify an installed runtime. The existing guarded cleanup
// verifies executable, working directory and process start time before stopping it.
type desktopRemote struct {
	config    *harnessConfig
	directory string
	started   bool
	platform  string
}

func desktopLocations(t *testing.T, binary string) *harnessConfig {
	t.Helper()
	cfg := &harnessConfig{runtimePath: binary, sshTarget: os.Getenv("BEE_DESKTOP_SSH"),
		remoteRuntimePath: os.Getenv("BEE_DESKTOP_REMOTE_RUNTIME"), remoteStageParent: os.Getenv("BEE_DESKTOP_REMOTE_STAGE_PARENT"),
		hostAddress: os.Getenv("BEE_DESKTOP_HOST_ADDRESS"), clientAddress: os.Getenv("BEE_DESKTOP_CLIENT_ADDRESS")}
	if err := validateConfig(cfg); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func newDesktopRemote(t *testing.T, ctx context.Context, cfg *harnessConfig) *desktopRemote {
	t.Helper()
	if cfg.sshTarget == "" {
		return nil
	}
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		t.Fatal(err)
	}
	platformCommand := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", cfg.sshTarget, "uname -s")
	platformBytes, err := platformCommand.Output()
	if err != nil {
		t.Fatalf("remote platform: %v", err)
	}
	platform := strings.TrimSpace(string(platformBytes))
	if platform != "Linux" && platform != "Darwin" {
		t.Fatalf("unsupported remote platform %q", platform)
	}
	remote := &desktopRemote{config: cfg, directory: filepath.Join(cfg.remoteStageParent, fmt.Sprintf("bee-desktop-proof-%x", token)), platform: platform}
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", cfg.sshTarget,
		"test -x "+shellQuote(cfg.remoteRuntimePath)+" && mkdir -m 0700 -- "+shellQuote(remote.directory))
	cmd.WaitDelay = 3 * time.Second
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("remote desktop stage: %v\n%s", err, output)
	}
	t.Cleanup(func() {
		if err := remote.cleanup(); err != nil {
			t.Error(err)
		}
	})
	return remote
}

func (r *desktopRemote) stage(t *testing.T, ctx context.Context, folder string) {
	t.Helper()
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", r.config.sshTarget, "tar -xf - -C "+shellQuote(r.directory))
	cmd.WaitDelay = 3 * time.Second
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	diagnostics := newSafeBuffer(64 * 1024)
	cmd.Stderr = diagnostics
	if err := cmd.Start(); err != nil {
		input.Close()
		t.Fatal(err)
	}
	archiveError := archiveDir(folder, input)
	closeError := input.Close()
	waitError := cmd.Wait()
	if archiveError != nil || closeError != nil || waitError != nil {
		t.Fatalf("remote desktop transfer: archive=%v close=%v wait=%v\n%s", archiveError, closeError, waitError, diagnostics.String())
	}
}

func (r *desktopRemote) lint(ctx context.Context) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", r.config.sshTarget,
		"cd "+shellQuote(r.directory)+" && "+shellQuote(r.config.remoteRuntimePath)+" lint --json")
	cmd.WaitDelay = 3 * time.Second
	return cmd
}

func desktopDatabaseEnvironment(folder string) []string {
	return append([]string{"GOMAXPROCS=2"}, beeDataEnv(folder)...)
}

func (r *desktopRemote) command(ctx context.Context) *exec.Cmd {
	assignments := desktopDatabaseEnvironment(r.directory)
	for i, value := range assignments {
		assignments[i] = shellQuote(value)
	}
	identity := "sed 's/^.*) //' /proc/$$/stat | awk '{print $20}'"
	if r.platform == "Darwin" {
		identity = "LC_ALL=C ps -p $$ -o lstart="
	}
	script := "cd " + shellQuote(r.directory) + " && echo $$ > host.pid && " + identity + " > host.starttime && exec env " + strings.Join(assignments, " ") + " " + shellQuote(r.config.remoteRuntimePath) + " run --console --override " + shellQuote(desktopSupervisorOverride) + " hive-desktop-admission-probe -- node-0"
	return exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", r.config.sshTarget, script)
}

// macOS has no /proc. Before every signal require this fixture's executable,
// working directory and recorded process start time. An identity mismatch keeps
// both the process and stage intact, just as the Linux cleanup does.
func (r *desktopRemote) cleanup() error {
	if r.platform != "Darwin" {
		return cleanupRemoteNodeA(r.config.sshTarget, r.directory, r.config.remoteRuntimePath, r.started)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	required := "0"
	if r.started {
		required = "1"
	}
	script := fmt.Sprintf(`
dir=%s
exe=%s
required=%s
[ -d "$dir" ] || exit 0
fail() { echo "$1; preserving $dir" >&2; exit 1; }
if [ "$required" = 1 ] && { [ ! -f "$dir/host.pid" ] || [ ! -f "$dir/host.starttime" ]; }; then
    fail "missing process identity"
fi
if [ -f "$dir/host.pid" ] || [ -f "$dir/host.starttime" ]; then
    [ -f "$dir/host.pid" ] && [ -f "$dir/host.starttime" ] || fail "incomplete process identity"
    pid=$(tr -d ' \t\n\r' < "$dir/host.pid")
    case "$pid" in ''|*[!0-9]*) fail "invalid process identity";; esac
    start=$(cat "$dir/host.starttime")
    [ -n "$start" ] || fail "missing start time"
    expected_dir=$(cd "$dir" && pwd -P)
    expected_exe=$(cd "$(dirname "$exe")" && pwd -P)/$(basename "$exe")
    matches() {
        current=$(LC_ALL=C ps -p "$pid" -o lstart=) || return 1
        [ "$current" = "$start" ] || return 1
        /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | grep -Fqx "n$expected_exe" || return 1
        /usr/sbin/lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep -Fqx "n$expected_dir"
    }
    if kill -0 "$pid" 2>/dev/null; then
        matches || fail "process identity mismatch before stop"
        kill -15 "$pid" 2>/dev/null || true
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
        if kill -0 "$pid" 2>/dev/null; then
            matches || fail "process identity mismatch before force-stop"
            kill -9 "$pid" 2>/dev/null || true
            i=0
            while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 0.1; i=$((i+1)); done
        fi
        kill -0 "$pid" 2>/dev/null && fail "owned process did not stop"
    fi
fi
rm -rf "$dir"
`, shellQuote(r.directory), shellQuote(r.config.remoteRuntimePath), required)
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", r.config.sshTarget, script)
	cmd.WaitDelay = 3 * time.Second
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("macOS fixture cleanup: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	return nil
}
