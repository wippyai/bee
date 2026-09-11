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
	app "github.com/wippyai/runtime/cmd/app"
)

func TestAttachmentRejectsInvalidRequestsBeforeDiscovery(t *testing.T) {
	state := filepath.Join(t.TempDir(), "not-created")
	client := Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: io.Discard}
	valid := app.LaunchRequest{Command: "bee", StateDir: state}
	cases := []app.LaunchRequest{
		{Command: "other", StateDir: state},
		{Command: "bee", Arguments: []string{"terminal"}, StateDir: state},
		{Command: "bee", StateDir: "relative"},
	}
	for _, request := range cases {
		if err := client.Attach(context.Background(), request); err == nil {
			t.Fatal("unsupported launch attached", request)
		}
	}
	if err := client.Attach(nil, valid); err == nil {
		t.Fatal("nil context accepted")
	}
	if _, err := os.Stat(state); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("attachment created owner state", err)
	}
}
