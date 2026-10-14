// SPDX-License-Identifier: MIT
package hive

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
	app "github.com/wippyai/runtime/cmd/app"
)

func TestMCPArguments(t *testing.T) {
	for _, tc := range []struct {
		args []string
		name string
	}{
		{[]string{"mcp", "connect"}, "External MCP client"},
		{[]string{"mcp", "connect", "--name", "Terminal Claude"}, "Terminal Claude"},
	} {
		name, err := mcpName(tc.args)
		require.NoError(t, err)
		require.Equal(t, tc.name, name)
	}
	for _, args := range [][]string{{"mcp"}, {"mcp", "other"}, {"mcp", "connect", "--name"}, {"mcp", "connect", "--name", ""}, {"mcp", "connect", "--name", "bad\nname"}, {"mcp", "connect", "--traits", "all"}} {
		_, err := mcpName(args)
		require.Error(t, err)
	}
}

func TestMCPRequiresRunningNode(t *testing.T) {
	isolatedConfig(t)
	_, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: t.TempDir(), Op: app.OpRun, Args: []string{"mcp", "connect"}})
	require.ErrorContains(t, err, "running node")
}

func TestMCPUsesTransientClientOnFolderNode(t *testing.T) {
	dir := isolatedConfig(t)
	require.NoError(t, Init(dir))
	state := t.TempDir()
	node, _, err := loadNode(state)
	require.NoError(t, err)
	holdState(t, state)
	plan, err := Component().Plan(context.Background(), app.Launch{Command: "bee", State: state, Op: app.OpRun, Args: []string{"mcp", "connect", "--name", "Terminal Claude"}})
	require.NoError(t, err)
	require.True(t, plan.Transient)
	require.Equal(t, "mcp", plan.Command)
	require.Equal(t, []string{node.Name, "Terminal Claude"}, plan.Args)
	require.NotNil(t, plan.Prepare)
	require.Nil(t, plan.Run)
}
