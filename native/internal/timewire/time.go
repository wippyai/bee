// SPDX-License-Identifier: MIT

// Package timewire handles Bee's canonical UTC timestamp representation.
package timewire

import (
	"errors"
	"time"
)

const layout = "2006-01-02T15:04:05.000Z"

// FormatCanonicalUTC formats t as UTC with millisecond precision.
func FormatCanonicalUTC(t time.Time) string {
	return t.UTC().Format(layout)
}

// ParseCanonicalUTC accepts only FormatCanonicalUTC's exact representation.
func ParseCanonicalUTC(value string) (time.Time, error) {
	parsed, err := time.Parse(layout, value)
	if err != nil || FormatCanonicalUTC(parsed) != value {
		return time.Time{}, errors.New("timestamp is not canonical UTC")
	}
	return parsed, nil
}
