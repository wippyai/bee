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
		state = filepath.Join(launch.State, "projects") + string(filepath.Separator) + "<sha256 of the working directory>"
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
		"  bee client [WORKSPACE DISPLAY]   join a running Bee with control; on a node without a folder",
		"                                   workspace, pick one of its workspaces (Ctrl+] returns to the picker)",
		"  bee attach WORKSPACE DISPLAY     join one display of a running Bee with control",
		"  bee desktops                     list the displays of a running Bee",
		"",
		"Workspaces (on a running Bee):",
		"  bee workspace list [--archived] [--after CURSOR]",
		"                                   list one page of the node's workspaces; NEXT names the cursor of the next",
		"  bee workspace roots              list the roots the host admits for workspaces and their access",
		"  bee workspace create LABEL ROOT[/PATH] [--new-folder]",
		"                                   add a workspace for the folder PATH under ROOT; --new-folder makes it",
		"                                   under a root admitted for writing",
		"  bee workspace archive WORKSPACE  stop serving a workspace whose host is not running",
		"  bee workspace restore WORKSPACE  serve an archived workspace again",
		"",
		"Hive:",
		"  bee hive invite                  print a one-line, single-use invite to this node's hive",
		"  bee hive invites                 list this node's invites and their status",
		"  bee hive revoke INVITE_ID        revoke a pending invite",
		"  bee hive join INVITE             join the hive an invite names; this node's owner must not be",
		"                                   running, and it starts in the hive",
		"  bee hive peers                   list this node's Hive peers and their supervisor sessions",
		"  bee hive leave NODE              retire the Hive peer NODE",
		"",
		"Processes:",
		"  bee start                        run this project's retained owner in the foreground",
		"  bee stop                         stop this project's owner and report when it has stopped; Ctrl+Q",
		"                                   in a desktop detaches only that client",
		"  bee daemon                       run this folder's node in the foreground without a folder workspace;",
		"                                   it serves the workspaces of its catalog to clients",
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
