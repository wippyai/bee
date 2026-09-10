// SPDX-License-Identifier: MIT

package rendezvous

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestHeldEnrollmentCrashHelper(t *testing.T) {
	dir := os.Getenv("BEE_LEASE_TEST_DIRECTORY")
	if dir == "" {
		return
	}
	e, err := NewEnrollment(dir)
	if err != nil {
		t.Fatal(err)
	}
	lease, _, err := e.RegisterHeld(context.Background(), sample().Execution, "crashed", bytes.Repeat([]byte{8}, 32))
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close(context.Background())
	fmt.Println("lease-held")
	time.Sleep(time.Minute)
}

func TestHeldEnrollmentReclaimsKilledProcessOnly(t *testing.T) {
	e, dir, _ := enrollmentFor(t)
	ctx := context.Background()
	key := bytes.Repeat([]byte{5}, 32)
	live, _, err := e.RegisterHeld(ctx, sample().Execution, "live", key)
	if err != nil {
		t.Fatal(err)
	}
	defer live.Close(ctx)
	if _, err := e.Register(ctx, sample().Execution, "unmanaged", key); err != nil {
		t.Fatal(err)
	}
	childCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(childCtx, os.Args[0], "-test.run=^TestHeldEnrollmentCrashHelper$")
	cmd.Env = append(os.Environ(), "BEE_LEASE_TEST_DIRECTORY="+dir)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() || scanner.Text() != "lease-held" {
		t.Fatalf("child not ready: %s %v", scanner.Text(), scanner.Err())
	}
	if _, ok := e.Resolve(ctx, sample().Execution, "crashed"); !ok {
		t.Fatal("child not enrolled")
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	replacement, state, err := e.RegisterHeld(ctx, sample().Execution, "replacement", key)
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Close(ctx)
	if len(state.peers) != 3 {
		t.Fatalf("unexpected peers: %d", len(state.peers))
	}
	for _, node := range []string{"live", "unmanaged", "replacement"} {
		if _, ok := state.PeerKey(node); !ok {
			t.Fatal("lost peer", node)
		}
	}
	if _, ok := state.PeerKey("crashed"); ok {
		t.Fatal("dead slot not reclaimed")
	}
	files, err := filepath.Glob(filepath.Join(dir, ".client-slot-*.lock"))
	if err != nil || len(files) != 2 {
		t.Fatalf("slot files: %d %v", len(files), err)
	}
}

func TestHeldEnrollmentCanceledCleanupReleasesSlot(t *testing.T) {
	e, _, _ := enrollmentFor(t)
	ctx := context.Background()
	key := bytes.Repeat([]byte{5}, 32)
	lease, _, err := e.RegisterHeld(ctx, sample().Execution, "old", key)
	if err != nil {
		t.Fatal(err)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if err := lease.Close(canceled); !errors.Is(err, context.Canceled) {
		t.Fatal("cleanup", err)
	}
	next, state, err := e.RegisterHeld(ctx, sample().Execution, "next", key)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close(ctx)
	if len(state.peers) != 1 {
		t.Fatal("stale enrollment remained")
	}
	_ = lease.Close(ctx)
	if _, ok := e.Resolve(ctx, sample().Execution, "next"); !ok {
		t.Fatal("stale close removed replacement")
	}
}
