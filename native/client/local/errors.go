// SPDX-License-Identifier: MIT

package local

import "errors"

var (
	// ErrClosed is returned when an operation is attempted on a closed listener.
	ErrClosed = errors.New("client/local: listener is closed")

	// ErrAcceptInProgress is returned when Accept is invoked while another Accept call is active.
	// This enforces an explicit single-Accept contract to eliminate global deadline races.
	ErrAcceptInProgress = errors.New("client/local: concurrent Accept is not supported")

	// ErrInvalidDescriptor is returned when an endpoint descriptor fails strict validation.
	ErrInvalidDescriptor = errors.New("client/local: invalid endpoint descriptor")

	// ErrAuthFailed is returned when mutual TLS client or server authentication fails.
	ErrAuthFailed = errors.New("client/local: mutual TLS authentication failed")

	// ErrHandshakeTimeout is returned when a TLS handshake exceeds its allocated timeout.
	ErrHandshakeTimeout = errors.New("client/local: handshake timed out")
)
