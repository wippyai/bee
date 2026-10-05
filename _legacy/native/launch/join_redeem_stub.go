//go:build !meshclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
)

// openRedeemer is unavailable when the native client packages are not compiled
// into this build. The sealed manifest enables the client tags.
func openRedeemer(context.Context, string) (redeemer, error) {
	return nil, errors.New("native Hive join is not compiled into this build")
}
