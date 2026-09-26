//go:build !windows

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	app "github.com/wippyai/runtime/cmd/app"
)

// cutoverStubSource is a tiny owner stand-in the acceptance builds twice.
// `help` proves the binary executes, `--state STATE run start` publishes a
// readiness file with the baked-in version and waits for SIGTERM, and
// `--state STATE stop` terminates that process over the detached channel.
const cutoverStubSource = `package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

func dir() string { return os.Getenv("CUTOVER_STUB_DIR") }

func main() {
	if len(os.Args) == 2 && os.Args[1] == "help" {
		fmt.Println("bee [--state DIR] [COMMAND ...]")
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "version" {
		fmt.Println(version)
		return
	}
	if len(os.Args) == 4 && os.Args[1] == "--state" && os.Args[3] == "stop" {
		stop()
		return
	}
	if len(os.Args) == 5 && os.Args[1] == "--state" && os.Args[3] == "run" && os.Args[4] == "start" {
		if os.Getenv("CUTOVER_STUB_FAIL") == version {
			fmt.Fprintln(os.Stderr, "stub owner refuses to boot")
			os.Exit(3)
		}
		serve()
		return
	}
	fmt.Fprintln(os.Stderr, "unknown stub command")
	os.Exit(2)
}

func stop() {
	data, err := os.ReadFile(filepath.Join(dir(), "pid"))
	if err != nil {
		fmt.Println("Bee is not running")
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		fmt.Fprintln(os.Stderr, "stub pid is invalid")
		os.Exit(1)
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		os.Exit(1)
	}
	_ = process.Signal(syscall.SIGTERM)
	for range 400 {
		if process.Signal(syscall.Signal(0)) != nil {
			_ = os.Remove(filepath.Join(dir(), "pid"))
			fmt.Println("Bee stopped")
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	fmt.Fprintln(os.Stderr, "stub owner did not stop")
	os.Exit(1)
}

func serve() {
	if err := os.MkdirAll(dir(), 0o700); err != nil {
		os.Exit(1)
	}
	if err := os.WriteFile(filepath.Join(dir(), "pid"), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600); err != nil {
		os.Exit(1)
	}
	if err := os.WriteFile(filepath.Join(dir(), "ready"), []byte(version+"\n"), 0o600); err != nil {
		os.Exit(1)
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	_ = os.Remove(filepath.Join(dir(), "ready"))
}
`

// buildCutoverStub compiles the stub source into a local binary reporting
// version.
func buildCutoverStub(t *testing.T, version string) string {
	t.Helper()
	source := t.TempDir()
	if err := os.WriteFile(filepath.Join(source, "go.mod"), []byte("module cutoverstub\n\ngo 1.27\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "main.go"), []byte(cutoverStubSource), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), "bee-"+version)
	command := exec.Command("go", "build", "-o", out, "-ldflags", "-X main.version="+version, ".")
	command.Dir = source
	command.Env = os.Environ()
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("build stub %s: %v: %s", version, err, output)
	}
	return out
}

// cutoverLiveSeams drives real stub processes: stops through the binary,
// polls the stub pid for the lock wait and starts detached owners with
// readiness polling.
func cutoverLiveSeams(t *testing.T, stubDir string, current *string) cutoverSeams {
	t.Helper()
	owned := func() bool {
		if _, err := os.Stat(filepath.Join(stubDir, "ready")); err != nil {
			return false
		}
		data, err := os.ReadFile(filepath.Join(stubDir, "pid"))
		if err != nil {
			return false
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
		if err != nil {
			return false
		}
		process, err := os.FindProcess(pid)
		if err != nil {
			return false
		}
		return process.Signal(syscall.Signal(0)) == nil
	}
	stop := func(ctx context.Context, state, binary string) error {
		command := exec.CommandContext(ctx, binary, "--state", state, "stop")
		if output, err := command.CombinedOutput(); err != nil {
			return fmt.Errorf("stub stop: %w: %s", err, output)
		}
		return nil
	}
	t.Cleanup(func() {
		if owned() {
			_ = stop(context.Background(), "", *current)
		}
	})
	return cutoverSeams{
		stopOld: func(ctx context.Context, state, _ string) error { return stop(ctx, state, *current) },
		stopOldCompatible: func(ctx context.Context, state, previous string) error {
			return stop(ctx, state, previous)
		},
		waitReleased: func(ctx context.Context, _ string) error {
			deadline := time.Now().Add(15 * time.Second)
			for owned() {
				if time.Now().After(deadline) {
					return fmt.Errorf("stub owner kept the state")
				}
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(25 * time.Millisecond):
				}
			}
			return nil
		},
		start: func(ctx context.Context, state, dir, executable string) error {
			prober := exec.Command(executable, "version")
			prober.Env = os.Environ()
			versioned, err := prober.Output()
			if err != nil {
				return fmt.Errorf("stub owner identity: %w", err)
			}
			wantVersion := strings.TrimSpace(string(versioned))
			command := exec.Command(executable, "--state", state, "run", "start")
			command.Dir = dir
			command.Env = os.Environ()
			command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
			if err := command.Start(); err != nil {
				return err
			}
			// Reap the detached child on exit so liveness polling sees
			// the release instead of a zombie.
			go func() { _ = command.Wait() }()
			deadline := time.Now().Add(15 * time.Second)
			for {
				data, err := os.ReadFile(filepath.Join(stubDir, "ready"))
				if err == nil && strings.TrimSpace(string(data)) == wantVersion {
					return nil
				}
				if time.Now().After(deadline) {
					return fmt.Errorf("stub owner %s did not publish readiness", filepath.Base(executable))
				}
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(25 * time.Millisecond):
				}
			}
		},
		currentExecutable: func() (string, error) { return *current, nil },
	}
}

func cutoverReady(t *testing.T, stubDir string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(stubDir, "ready"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(data))
}

func runCutoverCLI(t *testing.T, host *Host, state, dir string, args []string) (string, error) {
	t.Helper()
	t.Chdir(dir)
	arguments := append([]string{"--state", state}, args...)
	return captureStdout(t, func() error {
		return app.Run(context.Background(), app.Executable{Name: desktopCommand, Command: desktopCommand, Host: host}, arguments)
	})
}

// Two locally built binaries trade the running owner: the cutover verifies
// the confirmed digest, drains the old binary, hands the lock to the new one
// and retains the old for a one-step rollback.
func TestCutoverAcceptanceSwapsAndRollsBack(t *testing.T) {
	first := buildCutoverStub(t, "A")
	second := buildCutoverStub(t, "B")
	state := t.TempDir()
	project := t.TempDir()
	stubDir := t.TempDir()
	t.Setenv("CUTOVER_STUB_DIR", stubDir)
	current := first
	seams := cutoverLiveSeams(t, stubDir, &current)
	ctx := context.Background()

	if err := seams.start(ctx, state, project, first); err != nil {
		t.Fatal(err)
	}
	if got := cutoverReady(t, stubDir); got != "A" {
		t.Fatalf("running version = %q, want A", got)
	}
	secondDigest, err := sha256File(second)
	if err != nil {
		t.Fatal(err)
	}
	host := newHost(systemHostResolver())
	host.cutoverSeams = func() cutoverSeams { return seams }
	output, err := runCutoverCLI(t, host, state, project, []string{"upgrade", second, "--digest", secondDigest})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output, "Bee upgraded to "+secondDigest) || !strings.Contains(output, "bee upgrade --rollback") {
		t.Fatalf("upgrade output = %q", output)
	}
	if got := cutoverReady(t, stubDir); got != "B" {
		t.Fatalf("running version = %q, want B after the cutover", got)
	}
	firstDigest, err := sha256File(first)
	if err != nil {
		t.Fatal(err)
	}
	ledger, err := readCutoverLedger(state)
	if err != nil {
		t.Fatal(err)
	}
	retained, err := sha256File(ledger.Previous)
	if err != nil {
		t.Fatal(err)
	}
	if retained != firstDigest {
		t.Fatal("the cutover did not retain the previous binary")
	}
	current = second
	output, err = runCutoverCLI(t, host, state, project, []string{"upgrade", "--rollback"})
	if err != nil {
		t.Fatal(err)
	}
	if output != "Bee rolled back to the previous version.\n" {
		t.Fatalf("rollback output = %q", output)
	}
	if got := cutoverReady(t, stubDir); got != "A" {
		t.Fatalf("running version = %q, want A after the rollback", got)
	}
}

// A candidate that fails to boot falls back to the retained previous binary
// automatically, and the cutover reports both the failure and the fallback.
func TestCutoverAcceptanceFallsBackOnFailedBoot(t *testing.T) {
	first := buildCutoverStub(t, "A")
	second := buildCutoverStub(t, "B")
	state := t.TempDir()
	project := t.TempDir()
	stubDir := t.TempDir()
	t.Setenv("CUTOVER_STUB_DIR", stubDir)
	t.Setenv("CUTOVER_STUB_FAIL", "B")
	current := first
	seams := cutoverLiveSeams(t, stubDir, &current)
	ctx := context.Background()

	if err := seams.start(ctx, state, project, first); err != nil {
		t.Fatal(err)
	}
	secondDigest, err := sha256File(second)
	if err != nil {
		t.Fatal(err)
	}
	host := newHost(systemHostResolver())
	host.cutoverSeams = func() cutoverSeams { return seams }
	_, err = runCutoverCLI(t, host, state, project, []string{"upgrade", second, "--digest", secondDigest})
	if err == nil || !strings.Contains(err.Error(), "fell back to the previous binary") {
		t.Fatalf("failed boot = %v, want an automatic fallback report", err)
	}
	if got := cutoverReady(t, stubDir); got != "A" {
		t.Fatalf("running version = %q, want A after the fallback", got)
	}
}
