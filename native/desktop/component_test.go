//go:build meshclient && physicalclient

// SPDX-License-Identifier: MIT

package desktop

import (
	"context"
	"strings"
	"testing"

	app "github.com/wippyai/runtime/cmd/app"
)

func TestHookPostRoutePrecedesOwnerAndProjectRouting(t *testing.T) {
	called := false
	err := (&Host{}).Launch(context.Background(), app.LaunchRequest{
		Command:   "bee",
		Arguments: []string{"hook-post"},
	}, func(app.OwnerOptions) error {
		called = true
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "expected ENDPOINT ACTION_ID TOKEN_ENV EVENT") {
		t.Fatalf("hook-post routing error = %v", err)
	}
	if called {
		t.Fatal("hook-post entered owner runner")
	}
}
