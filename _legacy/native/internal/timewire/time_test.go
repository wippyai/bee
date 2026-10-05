// SPDX-License-Identifier: MIT

package timewire

import (
	"testing"
	"time"
)

func TestCanonicalUTCRoundTrip(t *testing.T) {
	value := FormatCanonicalUTC(time.Date(2026, time.September, 26, 12, 34, 56, 123456789, time.FixedZone("offset", -4*60*60)))
	if value != "2026-09-26T16:34:56.123Z" {
		t.Fatalf("formatted time = %q", value)
	}
	parsed, err := ParseCanonicalUTC(value)
	if err != nil || !parsed.Equal(time.Date(2026, time.September, 26, 16, 34, 56, 123000000, time.UTC)) {
		t.Fatalf("parsed time = %v, %v", parsed, err)
	}
}

func TestParseCanonicalUTCRejectsAlternateRepresentations(t *testing.T) {
	for _, value := range []string{
		"2026-09-26T16:34:56Z",
		"2026-09-26T16:34:56.123+00:00",
		"2026-09-26T16:34:56.1234Z",
	} {
		if _, err := ParseCanonicalUTC(value); err == nil {
			t.Errorf("accepted %q", value)
		}
	}
}
