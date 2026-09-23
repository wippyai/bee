// SPDX-License-Identifier: MIT

package launch

import (
	"path/filepath"
	"strings"

	app "github.com/wippyai/runtime/cmd/app"
)

// helpWords select the usage text. They are answered by the host before it
// selects a project, so help never reads or writes state.
var helpWords = map[string]bool{"help": true, "-h": true, "--help": true}

// usage is the whole Bee command grammar together with the state this
// invocation would use. It is computed from the launch alone.
func (host *Host) usage(launch app.Launch) string {
	var state string
	if launch.Explicit {
		state = launch.State + " (--state)"
	} else {
		root := launch.State
		if root == "" {
			root = host.defaultRoot
		}
		state = filepath.Join(root, "projects") + string(filepath.Separator) + "<sha256 of the working directory>"
	}
	return strings.Join([]string{
		"Usage: bee [--state DIR] [COMMAND [ARGUMENTS...]]",
		"",
		"Desktop:",
		"  bee                              open this project's desktop, starting its owner when none runs",
		"  bee NAME [ARGUMENTS...]          open the application command NAME (for example agent or terminal)",
		"                                   in the desktop; the owner resolves NAME against its admitted",
		"                                   applications and managed agents",
		"  bee observe [WORKSPACE DISPLAY]  watch a running Bee without control",
		"  bee client [WORKSPACE DISPLAY]   join a running Bee with control",
		"  bee attach WORKSPACE DISPLAY     join one display of a running Bee with control",
		"  bee desktops                     list the displays of a running Bee",
		"",
		"Processes:",
		"  bee start                        run this project's retained owner in the foreground",
		"  bee MODULE:ENTRY [ARGUMENTS...]  run one application entry directly (recovery and development)",
		"  bee hook-post ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT",
		"                                   post one harness hook event read from stdin",
		"  bee help | -h | --help           print this help",
		"",
		"Runtime:",
		"  bee update [ARGUMENTS...]        move the deployment forward from the Hub",
		"  bee recover [ARGUMENTS...]       boot the shipped packs afresh",
		"  bee wippy [ARGUMENTS...]         run the Wippy CLI on the deployment",
		"",
		"State:",
		"  --state DIR                      use DIR as the state directory; it precedes every command",
		"  State: " + state,
		"",
	}, "\n")
}
