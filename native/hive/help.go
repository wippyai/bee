// SPDX-License-Identifier: MIT

package hive

import "io"

const usage = `Bee: a terminal desktop for agents and apps.

Usage:
  bee                   open this folder's desktop
  bee NAME              open an app by its command name, such as bee claude
  bee client            display a running node's desktops
  bee node              run this folder's node without a display
  bee hive init         join every bee on this machine into one hive
  bee hive invite       print a token that joins another machine to this hive
  bee hive join TOKEN   join this machine to the hive the token names
  bee gov               revert a governed overlay to its retained baseline
  bee help              show this help
`

// Help writes the command overview.
func Help(out io.Writer) { _, _ = io.WriteString(out, usage) }

// isHelp reports whether args ask for the command overview.
func isHelp(args []string) bool {
	return len(args) == 1 && (args[0] == "help" || args[0] == "--help" || args[0] == "-h")
}
