//go:build windows && amd64 && computerfault

// SPDX-License-Identifier: MIT
package computer

import "github.com/wippyai/bee/native/computer/driver"

func configureInputFault() { driver.ConfigureAcceptanceFault() }
