// SPDX-License-Identifier: MIT
package hive

import (
	"errors"
	"strings"
)

func mcpName(args []string) (string, error) {
	name := "External MCP client"
	if len(args) == 4 && args[2] == "--name" {
		name = args[3]
	} else if len(args) != 2 {
		return "", errors.New("usage: bee mcp connect [--name NAME]")
	}
	if args[0] != "mcp" || args[1] != "connect" || len(name) == 0 || len(name) > 80 || strings.TrimSpace(name) == "" || strings.ContainsAny(name, "\r\n\t") {
		return "", errors.New("usage: bee mcp connect [--name NAME]; NAME is one line of at most 80 bytes")
	}
	for _, char := range name {
		if char < 32 || char == 127 {
			return "", errors.New("bee mcp connect: NAME contains a control character")
		}
	}
	return name, nil
}
