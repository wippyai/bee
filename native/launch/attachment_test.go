//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT
package launch

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/wippyai/bee/native/client/hive"
	application "github.com/wippyai/runtime/api/application"
)

func TestAttachmentRejectsUnrelatedLaunchesBeforeDiscovery(t *testing.T) {
	state := filepath.Join(t.TempDir(), "not-created")
	client := Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: io.Discard}
	valid := application.LaunchRequest{Operation: application.RunApplication, Command: "bee", StateDir: state}
	cases := map[string]application.LaunchRequest{}
	for _, operation := range []application.Operation{application.Update, application.RunRuntime} {
		request := valid
		request.Operation = operation
		cases[string(operation)] = request
	}
	request := valid
	request.Base = true
	cases["base"] = request
	request = valid
	request.Command = "bee-host"
	cases["other command"] = request
	request = valid
	request.Arguments = []string{"claude"}
	cases["launch arguments"] = request
	request = valid
	request.StateDir = "relative"
	cases["relative state"] = request
	for name, request := range cases {
		t.Run(name, func(t *testing.T) {
			if err := client.Attach(context.Background(), request); err == nil {
				t.Fatal("unsupported launch attached")
			}
		})
	}
	if err := client.Attach(nil, valid); err == nil {
		t.Fatal("nil context accepted")
	}
	if _, err := os.Stat(state); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("attachment created owner state", err)
	}
}
