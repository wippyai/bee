// SPDX-License-Identifier: MIT
package launch

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/wippyai/runtime/api/boot"
	"github.com/wippyai/runtime/api/event"
	"go.uber.org/zap"
)

type rejectedOwnerLog struct{ cause error }

func (output rejectedOwnerLog) Write([]byte) (int, error) { return 0, output.cause }

func TestOwnerLogPreservesOutputFailure(t *testing.T) {
	cause := errors.New("owner startup log is full")
	log := &bootLog{logger: zap.NewNop(), output: rejectedOwnerLog{cause: cause}}
	if err := log.capture(event.Event{Data: json.RawMessage(`{"entry":{"message":"Retained application restoration failed"},"fields":[{"key":"error","string":"original restoration reason"}]}`)}); !errors.Is(err, cause) {
		t.Fatalf("startup output error = %v", err)
	}
}

func TestOwnerLogRetainsExactRestorationReasonsWithoutDiagnosticLogging(t *testing.T) {
	var output bytes.Buffer
	log := &bootLog{logger: zap.NewNop(), output: &output}
	if err := log.capture(event.Event{Data: json.RawMessage(`{"entry":{"message":"Retained application restoration failed"},"fields":[{"key":"error","string":"application instance is attested for another app"},{"key":"instance_id","string":"retained-bad"},{"key":"workspace_id","string":"workspace"},{"key":"definition_id","string":"app"}]}`)}); err != nil {
		t.Fatal(err)
	}
	if err := log.capture(event.Event{Data: json.RawMessage(`{"entry":{"message":"unrelated payload"},"fields":[{"key":"error","string":"unrelated"}]}`)}); err != nil {
		t.Fatal(err)
	}
	if got := output.String(); got != "Retained application restoration failed: application instance is attested for another app [workspace=workspace, instance=retained-bad, definition=app]\n" {
		t.Fatal(got)
	}
}

func TestBootLogKeepsPhaseTimestampsAndRejectsUnrelatedPayloads(t *testing.T) {
	directory := t.TempDir()
	log, err := newBootLog(directory)
	if err != nil {
		t.Fatal(err)
	}
	log.phase("owner_spawn", "begin")
	log.capture(event.Event{Data: map[string]any{"entry": map[string]any{"message": "Boot phase", "time": int64(123)},
		"fields": []map[string]any{{"key": "phase", "string": "migration_check"}, {"key": "owner", "string": "workspace"}}}})
	log.capture(event.Event{Data: map[string]any{"entry": map[string]any{"message": "unrelated secret"}}})
	log.close()
	files, err := filepath.Glob(filepath.Join(directory, "boot-*.jsonl"))
	if err != nil || len(files) != 1 {
		t.Fatalf("files=%v err=%v", files, err)
	}
	file, err := os.Open(files[0])
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	var first, second map[string]any
	if err := decoder.Decode(&first); err != nil {
		t.Fatal(err)
	}
	if first["phase"] != "owner_spawn" || first["stage"] != "begin" || first["time_ns"] == nil {
		t.Fatal(first)
	}
	if err := decoder.Decode(&second); err != nil {
		t.Fatal(err)
	}
	if second["origin_ns"] != float64(123) || second["phase"] != "migration_check" || second["owner"] != "workspace" {
		t.Fatal(second)
	}
	var extra map[string]any
	if decoder.Decode(&extra) == nil {
		t.Fatal("unrelated log payload was retained")
	}
}

func TestBootLogDisabledWithoutDirectory(t *testing.T) {
	log, err := newBootLog("")
	if err != nil || log != nil {
		t.Fatalf("log=%v err=%v", log, err)
	}
	log.phase("unused", "point")
	log.close()
}

func TestBootLoggingPreservesHostAuthorityConfiguration(t *testing.T) {
	original := boot.NewConfig(boot.WithSection("cluster", map[string]any{"enabled": true, "internode.peer_key_source": "selected"}),
		boot.WithSection("override", map[string]any{"bee.hive.service:supervisor_service:input": "selected"}))
	logged := bootLoggingConfig(original)
	for _, key := range original.Keys() {
		before, _ := original.Get(key)
		after, _ := logged.Get(key)
		if before != after {
			t.Fatalf("boot logging changed host selection %q", key)
		}
	}
	if !logged.GetBool("logmanager.stream_to_events", false) {
		t.Fatal("event logging was not enabled")
	}
}
