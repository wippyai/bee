//go:build windows && amd64

// SPDX-License-Identifier: MIT
package driver

import (
	"bufio"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if len(os.Args) == 2 {
		if os.Getenv("BEE_TEST_HARDWARE") == "1" {
			guardLease = 30 * time.Second
		}
		if os.Args[1] == guardRole && os.Getenv("BEE_TEST_GUARD_STALL") == "1" {
			if err := os.WriteFile(os.Getenv("BEE_TEST_GUARD_PID"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
				os.Exit(3)
			}
			time.Sleep(30 * time.Second)
			os.Exit(4)
		}
		// Test executable only: inject a real down-prefix and deliberately hang.
		if os.Getenv("BEE_TEST_INPUT_PREFIX") == "1" {
			injectBatch = func(batch []input) int {
				n := rawInput(batch[:1])
				if path := os.Getenv("BEE_TEST_INJECTOR_PID"); path != "" {
					if err := os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
						os.Exit(3)
					}
				}
				time.Sleep(30 * time.Second)
				return n
			}
		}
		if handled, err := InputRole(os.Args[1]); handled {
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			os.Exit(0)
		}
	}
	os.Exit(m.Run())
}

func TestGuardStallReturnsUnresolved(t *testing.T) {
	if os.Getenv("BEE_COMPUTER_INPUT_TEST") != "1" {
		t.Skip("isolated interactive Windows VM only")
	}
	pidPath := filepath.Join(t.TempDir(), "guard.pid")
	t.Setenv("BEE_TEST_GUARD_STALL", "1")
	t.Setenv("BEE_TEST_GUARD_PID", pidPath)
	batch, _, err := shortcut("CTRL+A")
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if guardedInput(batch) {
		t.Fatal("stalled guardian reported success")
	}
	elapsed := time.Since(started)
	if elapsed > 5*time.Second {
		t.Fatalf("guardian caller exceeded shutdown bound: %s", elapsed)
	}
	if !lifecycleRetired.Load() {
		t.Fatal("failed guardian did not retire endpoint")
	}
	// This test process does not own a live driver lifecycle. Restore its local
	// test state only; production endpoints never clear permanent retirement.
	defer lifecycleRetired.Store(false)
	data, err := os.ReadFile(pidPath)
	if err != nil {
		t.Fatal(err)
	}
	processID, err := strconv.Atoi(string(data))
	if err != nil {
		t.Fatal(err)
	}
	p, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(processID))
	if err == nil {
		defer windows.CloseHandle(p)
		status, e := windows.WaitForSingleObject(p, 0)
		if e != nil || status != windows.WAIT_OBJECT_0 {
			t.Fatalf("stalled guardian still live: %d %v", status, e)
		}
	} else if err != windows.ERROR_INVALID_PARAMETER {
		t.Fatal(err)
	}
	t.Logf("stalled guardian terminated; caller returned unresolved and retired endpoint after %s", elapsed)
}

func TestGuardRecoversRealPrefix(t *testing.T) {
	if os.Getenv("BEE_COMPUTER_INPUT_TEST") != "1" {
		t.Skip("isolated interactive Windows VM only")
	}
	for _, mode := range []string{"disconnect", "expiry", "guard_exit", "foreign_input"} {
		t.Run(mode, func(t *testing.T) {
			batch, _, _ := shortcut("CTRL+A")
			releases, _ := releasePlan(batch)
			held := func() bool { v, _, _ := user32.NewProc("GetAsyncKeyState").Call(0xa2); return v&0x8000 != 0 }
			if held() {
				t.Fatal("Control already held")
			}
			session, err := sessionIdentity()
			if err != nil {
				t.Fatal(err)
			}
			c := inputCommand(guardRole)
			pidPath := filepath.Join(t.TempDir(), "injector.pid")
			c.Env = append(os.Environ(), "BEE_TEST_INPUT_PREFIX=1", "BEE_TEST_INJECTOR_PID="+pidPath)
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
			defer func() { in.Close(); c.Process.Kill(); c.Wait(); rawInput(releases) }()
			deadline := time.AfterFunc(6*time.Second, func() { in.Close(); out.Close() })
			defer deadline.Stop()
			if err = json.NewEncoder(in).Encode(inputPlan{Session: session, Batch: batch}); err != nil {
				t.Fatal(err)
			}
			r := bufio.NewReaderSize(out, 4096)
			line, err := r.ReadString('\n')
			if err != nil || line != "armed\n" {
				t.Fatalf("armed: %q %v", line, err)
			}
			if err = json.NewEncoder(in).Encode("commit"); err != nil {
				t.Fatal(err)
			}
			waitEffect(t, held)
			started := time.Now()
			if mode == "guard_exit" {
				var processID int
				waitEffect(t, func() bool {
					b, e := os.ReadFile(pidPath)
					if e != nil {
						return false
					}
					processID, e = strconv.Atoi(string(b))
					return e == nil && processID > 0
				})
				p, e := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(processID))
				if e != nil {
					t.Fatal(e)
				}
				defer windows.CloseHandle(p)
				if e = c.Process.Kill(); e != nil {
					t.Fatal(e)
				}
				c.Wait()
				status, e := windows.WaitForSingleObject(p, 2000)
				if e != nil || status != windows.WAIT_OBJECT_0 {
					t.Fatalf("injector survived guardian: status=%d %v", status, e)
				}
				if !held() {
					t.Fatal("expected unresolved native held state after both processes died")
				}
				if rawInput(releases) != len(releases) {
					t.Fatal("emergency observer release failed")
				}
				waitEffect(t, func() bool { return !held() })
				t.Log("killed guardian; kernel job terminated injector; Control remained held, so outcome is unresolved; observer cleanup verified")
				return
			}
			if mode == "disconnect" {
				in.Close()
			}
			if mode == "foreign_input" {
				if rawInput([]input{keyboard(0xa2, 0, 0)}) != 1 {
					t.Fatal("foreign Control-down failed")
				}
			}
			var receipt inputReceipt
			if err = readInputLine(r, &receipt); err != nil {
				t.Fatal(err)
			}
			if err = c.Wait(); err != nil {
				t.Fatal(err)
			}
			if mode == "foreign_input" {
				if receipt.Count != -1 || receipt.Cleanup != "input_overlap" || !held() {
					t.Fatalf("foreign hold altered: %+v held=%v", receipt, held())
				}
				if rawInput(releases) != len(releases) {
					t.Fatal("observer release failed")
				}
				waitEffect(t, func() bool { return !held() })
				t.Log("foreign native Control-down passed through; injector stopped; guardian did not release overlapping hold; observer cleanup verified")
				return
			}
			waitEffect(t, func() bool { return !held() })
			if receipt.Count != -1 || receipt.Cleanup != "submitted" {
				t.Fatalf("receipt: %+v", receipt)
			}
			t.Logf("native down observed; injector joined; guard cleanup independently verified after %s: %+v", time.Since(started), receipt)
		})
	}
}
