// SPDX-License-Identifier: MIT

package display

import "errors"

var (
	// ErrClosed reports that the display transport connection or session has closed.
	ErrClosed = errors.New("display: connection closed")

	// ErrUncertainDelivery reports that a connection dropped or timed out while an
	// input or resize request was in-flight awaiting host acknowledgment. In accordance
	// with Hive transport requirements, ambiguous delivery is exposed rather than retried.
	ErrUncertainDelivery = errors.New("display: uncertain delivery: connection lost with input in-flight")

	// ErrHandshakeMismatch reports that the remote party did not provide the exact expected
	// protocol version.
	ErrHandshakeMismatch = errors.New("display: protocol handshake version mismatch")

	// ErrOutOfSequence reports that an incoming input message sequence number did not match
	// the expected strictly increasing sequence.
	ErrOutOfSequence = errors.New("display: input sequence number out of order")

	// ErrPacketTooLarge reports that a framed wire packet exceeded the maximum bounded length.
	ErrPacketTooLarge = errors.New("display: packet length exceeds maximum bound")

	// ErrPacketTooSmall reports that a framed wire packet was smaller than the minimum bound.
	ErrPacketTooSmall = errors.New("display: packet length smaller than minimum bound")

	// ErrInvalidUTF8 reports that packet payload or string fields contain invalid UTF-8 bytes.
	ErrInvalidUTF8 = errors.New("display: packet contains invalid utf-8")

	// ErrTrailingContent reports that trailing non-whitespace data exists after a single message.
	ErrTrailingContent = errors.New("display: packet contains trailing content after message")

	// ErrUnknownField reports that a decoded object contained an unrecognized field name.
	ErrUnknownField = errors.New("display: message contains unknown field")

	// ErrDuplicateField reports that a decoded object contained duplicate or case-aliased keys.
	ErrDuplicateField = errors.New("display: message contains duplicate or case-aliased field")

	// ErrNullField reports that a non-nullable required field contained a null value.
	ErrNullField = errors.New("display: required field contains null value")

	// ErrMissingField reports that a required field is absent from the message payload.
	ErrMissingField = errors.New("display: required field is missing")

	// ErrInvalidMessage reports an unrecognized message type or malformed message structure.
	ErrInvalidMessage = errors.New("display: invalid message payload")

	// ErrInvalidEvent reports that event fields or kind violate native tty constraints.
	ErrInvalidEvent = errors.New("display: invalid event shape or fields")

	// ErrInvalidSnapshot reports that snapshot dimensions or rows violate native viewport bounds.
	ErrInvalidSnapshot = errors.New("display: invalid snapshot dimensions or content")
)
