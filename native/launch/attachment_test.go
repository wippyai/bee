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

func TestAttachmentRejectsUnrelatedLaunchesBeforeDiscovery(t *testing.T) {
	state := filepath.Join(t.TempDir(), "not-created")
	client := Client{Command: "bee", Mode: hive.Control, Stdin: os.Stdin, Stdout: io.Discard}
	valid := app.Launch{Op: app.OpRun, Command: "bee", State: state}
	cases := map[string]app.Launch{}
	// The model's reserved verbs never reach the client route; the launcher
	// plans them, so an attachment must refuse them here.
	for _, operation := range []app.Op{app.OpUpdate, app.OpRecover, app.OpWippy} {
		launch := valid
		launch.Op = operation
		cases[operation.String()] = launch
	}
	launch := valid
	launch.Command = "bee-host"
	cases["other command"] = launch
	launch = valid
	launch.Args = []string{"claude"}
	cases["launch arguments"] = launch
	launch = valid
	launch.State = "relative"
	cases["relative state"] = launch
	for name, launch := range cases {
		t.Run(name, func(t *testing.T) {
			if err := client.Attach(context.Background(), launch); err == nil {
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
