// SPDX-License-Identifier: MIT

package launch

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"
)

// workspaceCommand is one `bee workspace` invocation against the running
// owner's workspace catalog.
type workspaceCommand struct {
	verb      string
	id        string
	label     string
	root      string
	path      string
	newFolder bool
	archived  bool
	after     string
}

const (
	workspaceList    = "list"
	workspaceRoots   = "roots"
	workspaceCreate  = "create"
	workspaceArchive = "archive"
	workspaceRestore = "restore"
	// maxLabelBytes and maxPathBytes are the catalog's own bounds.
	maxLabelBytes = 240
	maxPathBytes  = 512
	maxRootBytes  = 160
	maxCursor     = 2200
)

var workspaceUsage = errors.New("bee workspace takes list [--archived] [--after CURSOR], roots, create LABEL ROOT[/PATH] [--new-folder], archive WORKSPACE or restore WORKSPACE")

// parseWorkspace decodes `bee workspace VERB [ARGUMENTS]` before any state is
// selected. The owner's catalog still decodes and authorizes every request.
func parseWorkspace(args []string) (workspaceCommand, error) {
	if len(args) < 2 {
		return workspaceCommand{}, workspaceUsage
	}
	verb, rest := args[1], args[2:]
	switch verb {
	case workspaceRoots:
		if len(rest) != 0 {
			return workspaceCommand{}, errors.New("bee workspace roots takes no arguments")
		}
		return workspaceCommand{verb: verb}, nil
	case workspaceList:
		command := workspaceCommand{verb: verb}
		for index := 0; index < len(rest); index++ {
			switch {
			case rest[index] == "--archived" && !command.archived:
				command.archived = true
			case rest[index] == "--after" && command.after == "" && index+1 < len(rest) && validCursor(rest[index+1]):
				command.after = rest[index+1]
				index++
			default:
				return workspaceCommand{}, errors.New("bee workspace list takes --archived and --after CURSOR")
			}
		}
		return command, nil
	case workspaceArchive, workspaceRestore:
		if len(rest) != 1 || !validWorkspaceID(rest[0]) {
			return workspaceCommand{}, fmt.Errorf("bee workspace %s requires a WORKSPACE identity of 32 lowercase hexadecimal characters", verb)
		}
		return workspaceCommand{verb: verb, id: rest[0]}, nil
	case workspaceCreate:
		command := workspaceCommand{verb: verb}
		var words []string
		for _, word := range rest {
			if word == "--new-folder" && !command.newFolder {
				command.newFolder = true
				continue
			}
			words = append(words, word)
		}
		if len(words) != 2 {
			return workspaceCommand{}, errors.New("bee workspace create requires LABEL and ROOT[/PATH]")
		}
		command.label = words[0]
		if command.label == "" || len(command.label) > maxLabelBytes || !utf8.ValidString(command.label) || hasControl(command.label) {
			return workspaceCommand{}, fmt.Errorf("a workspace label is one line of 1 to %d bytes", maxLabelBytes)
		}
		command.root, command.path, _ = strings.Cut(words[1], "/")
		if command.root == "" || len(command.root) > maxRootBytes || hasControl(command.root) {
			return workspaceCommand{}, errors.New("ROOT names a root the host admits; run bee workspace roots")
		}
		if !validSubpath(command.path) {
			return workspaceCommand{}, errors.New("PATH is relative, without empty, . or .. segments")
		}
		if command.newFolder && command.path == "" {
			return workspaceCommand{}, errors.New("--new-folder needs a PATH to make")
		}
		return command, nil
	}
	return workspaceCommand{}, workspaceUsage
}

func validWorkspaceID(id string) bool {
	decoded, err := hex.DecodeString(id)
	return err == nil && len(decoded) == 16 && hex.EncodeToString(decoded) == id
}

func validCursor(value string) bool {
	if value == "" || len(value) > maxCursor {
		return false
	}
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') && r != ':' {
			return false
		}
	}
	return true
}

func hasControl(value string) bool {
	for _, r := range value {
		if r < 32 || r == 127 {
			return true
		}
	}
	return false
}

func validSubpath(path string) bool {
	if path == "" {
		return true
	}
	if len(path) > maxPathBytes || !utf8.ValidString(path) || hasControl(path) || strings.Contains(path, "\\") {
		return false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return true
}
