//go:build !meshclient || !physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"

	app "github.com/wippyai/runtime/cmd/app"
)

// runClientRoute is unavailable when the native client packages are not compiled
// into this build. The sealed manifest enables the client tags.
func runClientRoute(context.Context, app.Launch, clientIntent) error {
	return errors.New("native client route is not compiled into this build")
}
