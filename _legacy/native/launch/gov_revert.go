// SPDX-License-Identifier: MIT

package launch

import (
	"errors"
	"strings"
)

const governanceRecoveryCommand = "bee-gov"

type governanceCommand struct {
	owner string
}

func parseGovernance(args []string) (*governanceCommand, bool, error) {
	if len(args) == 0 || args[0] != "gov" {
		return nil, false, nil
	}
	if len(args) != 3 || args[1] != "revert" || !validOverlayOwner(args[2]) {
		return nil, true, errors.New("bee gov revert requires one valid OWNER")
	}
	return &governanceCommand{owner: args[2]}, true, nil
}

func validOverlayOwner(value string) bool {
	if len(value) < 3 || len(value) > 160 || strings.Count(value, ":") != 1 {
		return false
	}
	separator := strings.IndexByte(value, ':')
	if separator < 2 || value[0] < 'a' || value[0] > 'z' {
		return false
	}
	for _, part := range []string{value[:separator], value[separator+1:]} {
		if part == "" || strings.Contains(part, "..") || strings.HasPrefix(part, ".") || strings.HasSuffix(part, ".") {
			return false
		}
		for _, char := range part {
			if char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' ||
				char == '_' || char == '.' || char == '-' {
				continue
			}
			return false
		}
	}
	return true
}
