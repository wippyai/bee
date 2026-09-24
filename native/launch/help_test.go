// SPDX-License-Identifier: MIT

package launch

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	app "github.com/wippyai/runtime/cmd/app"
)

// untouchedLaunch returns a state root that is a regular file and a working
// directory that does not exist, so any project selection or state read fails
// the launch, and a check that both are left as they were.
func untouchedLaunch(t *testing.T) (string, string, func()) {
	t.Helper()
	base := t.TempDir()
	state := filepath.Join(base, "state")
	if err := os.WriteFile(state, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(base, "missing")
	return state, missing, func() {
		t.Helper()
		info, err := os.Stat(state)
		if err != nil || !info.Mode().IsRegular() {
			t.Fatalf("launch changed the state root: %v", err)
		}
		if _, err := os.Stat(missing); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("launch created the working directory: %v", err)
		}
		entries, err := os.ReadDir(base)
		if err != nil || len(entries) != 1 {
			t.Fatalf("launch wrote beside the state root: %v %v", entries, err)
		}
	}
}

// captureStdout runs fn with os.Stdout redirected and returns what it wrote.
func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = writer
	output := make(chan string, 1)
	go func() {
		data, _ := io.ReadAll(reader)
		output <- string(data)
	}()
	result := fn()
	os.Stdout = stdout
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return <-output, result
}

// Help answers from the executable alone: it never selects a project, reads a
// state directory, prepares an owner or joins a mesh.
func TestPlanAnswersHelpBeforeProjectSelection(t *testing.T) {
	for _, word := range []string{"help", "-h", "--help"} {
		state, missing, untouched := untouchedLaunch(t)
		host := newHost(systemHostResolver())
		plan, err := host.Plan(context.Background(), app.Launch{
			Op: app.OpRun, Command: desktopCommand, State: state, Dir: missing, Args: []string{word},
		})
		if err != nil {
			t.Fatalf("%s planning touched project selection: %v", word, err)
		}
		if plan.Run == nil || plan.Prepare != nil || plan.DefaultState != "" || plan.Command != "" || plan.Args != nil || plan.Transient {
			t.Fatalf("%s plan = %#v", word, plan)
		}
		if host.ownerState != "" {
			t.Fatalf("%s selected owner state %q", word, host.ownerState)
		}
		output, err := captureStdout(t, func() error { return plan.Run(context.Background()) })
		if err != nil {
			t.Fatalf("%s run: %v", word, err)
		}
		for _, want := range []string{
			"Usage: bee [--state DIR] [COMMAND [ARGUMENTS...]]",
			"\n  bee  ",
			"bee observe [WORKSPACE DISPLAY]",
			"bee client [WORKSPACE DISPLAY]",
			"bee attach WORKSPACE DISPLAY",
			"bee desktops",
			"bee NAME [ARGUMENTS...]",
			"bee MODULE:ENTRY [ARGUMENTS...]",
			"bee start",
			"bee daemon",
			"bee hook-post ENDPOINT ACTION_ID TOKEN_ENV_OR_FILE EVENT",
			"bee workspace list [--archived] [--after CURSOR]",
			"bee workspace roots",
			"bee workspace create LABEL ROOT[/PATH] [--new-folder]",
			"bee workspace archive WORKSPACE",
			"bee workspace restore WORKSPACE",
			"bee hive invite",
			"bee hive invites",
			"bee hive revoke INVITE_ID",
			"bee hive join INVITE",
			"bee hive peers",
			"bee hive leave NODE",
			"bee help",
			"bee update",
			"bee recover",
			"bee wippy",
			"--state DIR",
			filepath.Join(state, "projects") + string(filepath.Separator) + "<sha256 of the working directory>",
		} {
			if !strings.Contains(output, want) {
				t.Fatalf("%s output lacks %q:\n%s", word, want, output)
			}
		}
		untouched()
	}
}

// An explicit --state names the state the help describes.
func TestHelpNamesExplicitState(t *testing.T) {
	state, missing, untouched := untouchedLaunch(t)
	host := newHost(systemHostResolver())
	plan, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, State: state, Dir: missing, Args: []string{"--help"}, Explicit: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	output, err := captureStdout(t, func() error { return plan.Run(context.Background()) })
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output, "State: "+state+" (--state)") {
		t.Fatalf("help does not name the explicit state:\n%s", output)
	}
	untouched()
}

func TestPlanRefusesHelpWithArguments(t *testing.T) {
	state, missing, untouched := untouchedLaunch(t)
	host := newHost(systemHostResolver())
	_, err := host.Plan(context.Background(), app.Launch{
		Op: app.OpRun, Command: desktopCommand, State: state, Dir: missing, Args: []string{"help", "agent"},
	})
	if err == nil || err.Error() != "bee help takes no arguments" {
		t.Fatalf("help with arguments = %v", err)
	}
	untouched()
}

// A word that cannot name an application command is refused by the host
// before it selects a project; it never reaches an owner.
func TestPlanRefusesMalformedCommandBeforeProjectSelection(t *testing.T) {
	for _, word := range []string{"-x", "--nope", "--version", "Agent", "terminal;id", strings.Repeat("x", 41)} {
		state, missing, untouched := untouchedLaunch(t)
		host := newHost(systemHostResolver())
		_, err := host.Plan(context.Background(), app.Launch{
			Op: app.OpRun, Command: desktopCommand, State: state, Dir: missing, Args: []string{word},
		})
		want := "unknown Bee command " + `"` + word + `"; run bee --help`
		if err == nil || err.Error() != want {
			t.Fatalf("%q plan error = %v, want %q", word, err, want)
		}
		if host.ownerState != "" {
			t.Fatalf("%q selected owner state %q", word, host.ownerState)
		}
		untouched()
	}
}

// Malformed route arguments are refused before project selection as well.
func TestPlanRefusesMalformedRouteBeforeProjectSelection(t *testing.T) {
	for _, case_ := range []struct {
		args []string
		want string
	}{
		{[]string{"attach"}, "bee attach requires WORKSPACE DISPLAY; bee observe/client takes no application arguments or one WORKSPACE DISPLAY pair"},
		{[]string{"desktops", "extra"}, "bee desktops takes no arguments"},
		{[]string{"agent", "line\nfeed"}, "invalid Bee command arguments"},
		{[]string{"hive"}, "bee hive takes invite, invites, peers, revoke INVITE_ID, join INVITE or leave NODE"},
		{[]string{"workspace"}, "bee workspace takes list [--archived] [--after CURSOR], roots, create LABEL ROOT[/PATH] [--new-folder], archive WORKSPACE or restore WORKSPACE"},
		{[]string{"workspace", "archive", "nope"}, "bee workspace archive requires a WORKSPACE identity of 32 lowercase hexadecimal characters"},
		{[]string{"hive", "invite", "now"}, "bee hive invite takes no arguments"},
		{[]string{"hive", "revoke", "ABC"}, "an invite id is 32 lowercase hexadecimal characters"},
		{[]string{"hive", "join", "https://example.test"}, "invalid Bee Hive invite"},
		{[]string{"hive", "leave", "../node"}, "bee hive leave requires a NODE identity"},
	} {
		state, missing, untouched := untouchedLaunch(t)
		host := newHost(systemHostResolver())
		_, err := host.Plan(context.Background(), app.Launch{
			Op: app.OpRun, Command: desktopCommand, State: state, Dir: missing, Args: case_.args,
		})
		if err == nil || err.Error() != case_.want {
			t.Fatalf("%q plan error = %v, want %q", case_.args, err, case_.want)
		}
		untouched()
	}
}
