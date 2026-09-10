//go:build windows && amd64 && computerfault

// SPDX-License-Identifier: MIT
// Explicit acceptance build only. Never included in the ordinary Bee binary.
package driver

import (
	"os"
	"strconv"
	"time"
)

func ConfigureAcceptanceFault() {
	if os.Getenv("BEE_OWNER_INPUT_FAULT") != "1" || len(os.Args) != 2 {
		return
	}
	if os.Args[1] == guardRole {
		if err := os.WriteFile(os.Getenv("BEE_OWNER_GUARD_PID"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
			os.Exit(3)
		}
	}
	if os.Args[1] == injectRole {
		injectBatch = func(batch []input) int {
			n := rawInput(batch[:1])
			if err := os.WriteFile(os.Getenv("BEE_OWNER_INJECT_PID"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
				os.Exit(3)
			}
			time.Sleep(30 * time.Second)
			return n
		}
	}
}
