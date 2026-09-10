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
	remote := &desktopRemote{config: cfg, directory: filepath.Join(cfg.remoteStageParent, fmt.Sprintf("bee-desktop-proof-%x", token))}
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", cfg.sshTarget,
		"test \"$(uname -s)\" = Linux && test -x "+shellQuote(cfg.remoteRuntimePath)+" && mkdir -m 0700 -- "+shellQuote(remote.directory))
	cmd.WaitDelay = 3 * time.Second
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("remote desktop stage: %v\n%s", err, output)
	}
	t.Cleanup(func() {
		if err := cleanupRemoteNodeA(cfg.sshTarget, remote.directory, cfg.remoteRuntimePath, remote.started); err != nil {
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
	result := []string{"GOMAXPROCS=2"}
	for _, name := range []string{"WORKSPACE", "THREADS", "CLIENT", "APPROVALS", "RESOURCES", "CREDENTIALS", "PLACEMENT"} {
		result = append(result, "BEE_"+name+"_DB="+filepath.Join(folder, strings.ToLower(name)+".db"))
	}
	return result
}

func (r *desktopRemote) command(ctx context.Context) *exec.Cmd {
	assignments := desktopDatabaseEnvironment(r.directory)
	for i, value := range assignments {
		assignments[i] = shellQuote(value)
	}
	script := "cd " + shellQuote(r.directory) + " && echo $$ > host.pid && sed 's/^.*) //' /proc/$$/stat | awk '{print $20}' > host.starttime && exec env " + strings.Join(assignments, " ") + " " + shellQuote(r.config.remoteRuntimePath) + " run --console hive-desktop-admission-probe -- node-0"
	return exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "--", r.config.sshTarget, script)
}
