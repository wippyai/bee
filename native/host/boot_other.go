// SPDX-License-Identifier: MIT

//go:build !linux && !darwin && !windows

package host

// systemBootID is absent where the platform names no boot identity.
var systemBootID func() (string, error)
