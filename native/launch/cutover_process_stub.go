//go:build !meshclient || !physicalclient

// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
)

// defaultCutoverSeams is unavailable when the native client packages are not
// compiled into this build. The sealed manifest enables the client tags.
func defaultCutoverSeams() cutoverSeams {
	failed := func(context.Context, ...string) error {
		return errors.New("native cutover is not compiled into this build")
	}
	return cutoverSeams{
		stopOld: func(ctx context.Context, state, dir string) error { return failed(ctx) },
		stopOldCompatible: func(ctx context.Context, state, previous string) error {
			return failed(ctx)
		},
		waitReleased: waitReleased,
		start: func(ctx context.Context, state, dir, executable string) error {
			return failed(ctx)
		},
		currentExecutable: func() (string, error) {
			return "", errors.New("native cutover is not compiled into this build")
		},
	}
}
