// SPDX-License-Identifier: MIT
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// This opt-in acceptance uses a real CLI and a selected login file, but submits
// no model prompt. Machine settings and trust state are never copied.
func TestActualGrokManagedStartup(t *testing.T) {
	binary := os.Getenv("BEE_BINARY")
	executable := os.Getenv("GROK_BIN")
	loginSource := os.Getenv("GROK_LOGIN_FILE")
	if binary == "" || executable == "" || loginSource == "" {
		t.Fatal("BEE_BINARY, GROK_BIN and GROK_LOGIN_FILE are required")
	}
	binary, err := filepath.Abs(binary)
	if err != nil {
		t.Fatal(err)
	}
	executable, err = filepath.Abs(executable)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	project, state, home := filepath.Join(root, "project"), filepath.Join(root, "state"), filepath.Join(root, "home")
	if err := os.MkdirAll(filepath.Join(project, "bin"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(executable, filepath.Join(project, "bin", "grok")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(home, ".grok"), 0700); err != nil {
		t.Fatal(err)
	}
	login, err := os.ReadFile(loginSource)
	if err != nil {
		t.Fatal("machine login unavailable")
	}
	if err := os.WriteFile(filepath.Join(home, ".grok", "auth.json"), login, 0600); err != nil {
		t.Fatal(err)
	}
	ui, err := newDesktop(binary, project, state, home)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		ui.close()
		if err := stopFixtureOwners(binary, state); err != nil {
			t.Errorf("stop fixture owners: %v", err)
		}
	}()
	if err := ui.waitFor("Choose a profile", 25*time.Second); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		_, before, _ := ui.snapshot()
		if err := ui.send("\x1b[B"); err != nil {
			t.Fatal(err)
		}
		if err := ui.waitForAfter("Choose a profile", before, 5*time.Second); err != nil {
			t.Fatal(err)
		}
	}
	if err := ui.send("\r"); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		db, err := openRecoveryDB(filepath.Join(state, "threads.db"))
		if err != nil {
			t.Fatal(err)
		}
		rows, err := db.Query("SELECT record_json FROM bee_thread_records WHERE kind='observation' AND source='bee'")
		found := false
		if err == nil {
			for rows.Next() {
				var raw string
				if err := rows.Scan(&raw); err != nil {
					rows.Close()
					db.Close()
					t.Fatal(err)
				}
				var rec struct {
					Body struct {
						Data struct {
							Name    string `json:"event_name"`
							Payload string `json:"payload_json"`
						} `json:"data"`
					} `json:"body"`
				}
				if json.Unmarshal([]byte(raw), &rec) != nil || rec.Body.Data.Name != "bee.harness.hook" {
					continue
				}
				var payload struct {
					Event  string         `json:"event"`
					Fields map[string]any `json:"fields"`
				}
				if json.Unmarshal([]byte(rec.Body.Data.Payload), &payload) == nil && payload.Event == "SessionStart" {
					session, ok := payload.Fields["session_id"].(string)
					found = found || (ok && session != "")
				}
			}
			readErr := rows.Err()
			rows.Close()
			if readErr != nil {
				db.Close()
				t.Fatal(readErr)
			}
		}
		db.Close()
		if found {
			t.Log("Actual Grok emitted SessionStart through generated hook configuration into its bound Bee thread; no prompt submitted")
			if err := ui.quit(); err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("actual Grok startup hook did not commit within 30 seconds")
}
