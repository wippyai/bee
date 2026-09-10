//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"bufio"
	"encoding/json"
	"os"
	"testing"
	"time"
)

func TestHardwareOverlap(t *testing.T) {
	if os.Getenv("BEE_TEST_HARDWARE") != "1" {
		t.Skip("externally coordinated emulated keyboard test only")
	}
	readyPath := os.Getenv("BEE_TEST_HARDWARE_READY")
	if readyPath == "" {
		t.Fatal("readiness path required")
	}
	if _, err := os.Stat(readyPath); !os.IsNotExist(err) {
		t.Fatal("readiness path already exists or cannot be checked")
	}
	held := func() bool { s, _, _ := user32.NewProc("GetAsyncKeyState").Call(0xa2); return s&0x8000 != 0 }
	if held() {
		t.Fatal("Control already held")
	}
	batch, _, _ := shortcut("CTRL+A")
	releases, _ := releasePlan(batch)
	session, err := sessionIdentity()
	if err != nil {
		t.Fatal(err)
	}
	c := inputCommand(guardRole)
	c.Env = append(os.Environ(), "BEE_TEST_INPUT_PREFIX=1")
	in, err := c.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := c.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = c.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { in.Close(); c.Process.Kill(); c.Wait(); rawInput(releases); os.Remove(readyPath) }()
	deadline := time.AfterFunc(40*time.Second, func() { in.Close(); out.Close() })
	defer deadline.Stop()
	if err = json.NewEncoder(in).Encode(inputPlan{Session: session, Batch: batch}); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReaderSize(out, 4096)
	line, err := r.ReadString('\n')
	if err != nil || line != "armed\n" {
		t.Fatalf("guardian readiness: %q %v", line, err)
	}
	if err = json.NewEncoder(in).Encode("commit"); err != nil {
		t.Fatal(err)
	}
	waitEffect(t, held)
	if err = os.WriteFile(readyPath, []byte("native-control-down"), 0600); err != nil {
		t.Fatal(err)
	}
	var receipt inputReceipt
	if err = readInputLine(r, &receipt); err != nil {
		t.Fatal(err)
	}
	if err = c.Wait(); err != nil {
		t.Fatal(err)
	}
	if receipt.Count != -1 || receipt.Cleanup != "input_overlap" || !receipt.PhysicalOverlap || !held() {
		t.Fatalf("hardware hold not preserved: %+v held=%v", receipt, held())
	}
	// The host holds the emulated key for five seconds. Require natural release
	// before emergency cleanup; a synthesized observer release cannot pass this.
	until := time.Now().Add(8 * time.Second)
	for held() {
		if time.Now().After(until) {
			t.Fatal("hardware key did not release")
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Log("non-injected keyboard event observed; guardian/injector exited; overlapping Control stayed down until QEMU released it; no observer release used")
}
