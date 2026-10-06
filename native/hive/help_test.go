// SPDX-License-Identifier: MIT

package hive

import (
	"bytes"
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestHelpPrintsUsageWithoutBootingANodeOrADisplay(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	owned := t.TempDir()
	holdState(t, owned)
	for _, state := range []string{t.TempDir(), owned} {
		for _, word := range []string{"help", "--help", "-h"} {
			plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun, Args: []string{word}})
			require.NoError(t, err, word)
			require.NotNil(t, plan.Run, word)
			require.Nil(t, plan.Prepare, "help boots nothing: %s", word)
			require.False(t, plan.Transient, word)
		}
	}
	var out bytes.Buffer
	Help(&out)
	for _, line := range []string{"bee hive invite", "bee hive join TOKEN", "bee node", "bee client", "bee NAME"} {
		require.Contains(t, out.String(), line)
	}
}
