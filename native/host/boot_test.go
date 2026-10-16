// SPDX-License-Identifier: MIT

//go:build linux || darwin || windows

package host

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSystemBootIdentityIsStableWithinOneBoot(t *testing.T) {
	read := systemHostResolver().bootID
	require.NotNil(t, read)
	first, err := read()
	require.NoError(t, err)
	require.NotEmpty(t, first)
	second, err := read()
	require.NoError(t, err)
	require.Equal(t, first, second)
}
