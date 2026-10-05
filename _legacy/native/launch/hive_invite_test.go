// SPDX-License-Identifier: MIT

package launch

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInviteHintNamesTheJoinCommandForTheOtherNode(t *testing.T) {
	line := "bee-hive://id:secret@127.0.0.1:1/bee-owner-a?key=k"
	want := "Single use. On the node that joins, with its Bee stopped, run:\n  bee hive join " + line + "\n"
	if got := inviteHint(line); got != want {
		t.Fatalf("hint = %q, want %q", got, want)
	}
}

// `bee hive invite --out FILE` writes the invite to the file with owner-only
// permissions and prints no secret to stdout; `--share DIR` writes it under
// the shared directory the person picked.
func TestInviteOutAndShareWriteTheInviteToAFile(t *testing.T) {
	base := t.TempDir()
	line := "bee-hive://id:secret@127.0.0.1:1/bee-owner-a?key=k"

	out := filepath.Join(base, "invite.txt")
	path, err := writeInviteFile(out, line)
	if err != nil || path != out {
		t.Fatalf("--out wrote %q, %v", path, err)
	}
	data, err := os.ReadFile(out)
	if err != nil || string(data) != line+"\n" {
		t.Fatalf("invite file = %q, %v", data, err)
	}
	info, err := os.Stat(out)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("invite file mode = %v, %v", info, err)
	}
	// An existing file is never overwritten: the invite is a credential and
	// clobbering a path would destroy whatever was there.
	if _, err := writeInviteFile(out, line); err == nil {
		t.Fatal("--out overwrote an existing file")
	}

	shared, err := writeSharedInvite(base, line)
	if err != nil || shared != filepath.Join(base, shareInviteName) {
		t.Fatalf("--share wrote %q, %v", shared, err)
	}
	if data, err := os.ReadFile(shared); err != nil || string(data) != line+"\n" {
		t.Fatalf("shared invite = %q, %v", data, err)
	}
	if _, err := writeSharedInvite(filepath.Join(base, "missing"), line); err == nil {
		t.Fatal("--share accepted a missing directory")
	}
	if _, err := writeSharedInvite(out, line); err == nil {
		t.Fatal("--share accepted a regular file")
	}
	// The hint names the file and never repeats the secret on a terminal line
	// other than the join command the person runs.
	hint := inviteFileHint(shared)
	if !strings.Contains(hint, shared) || !strings.Contains(hint, "bee hive join") {
		t.Fatalf("file hint = %q", hint)
	}
}

// The invite grammar accepts --out and --share, and refuses combinations that
// would silently drop one of them.
func TestParseHiveInviteOutputFlags(t *testing.T) {
	for _, tc := range []struct {
		args    []string
		wantOut string
		wantShr string
	}{
		{[]string{"hive", "invite"}, "", ""},
		{[]string{"hive", "invite", "--out", "/tmp/i.txt"}, "/tmp/i.txt", ""},
		{[]string{"hive", "invite", "--share", "/mnt/shared"}, "", "/mnt/shared"},
	} {
		command, err := parseHive(tc.args)
		if err != nil {
			t.Fatalf("%v: %v", tc.args, err)
		}
		if command.verb != hiveInvite || command.out != tc.wantOut || command.share != tc.wantShr {
			t.Fatalf("%v = %+v", tc.args, command)
		}
	}
	for _, args := range [][]string{
		{"hive", "invite", "--out"},
		{"hive", "invite", "--share"},
		{"hive", "invite", "--out", "a", "--share", "b"},
		{"hive", "invite", "--share", "a", "--out", "b"},
		{"hive", "invites", "--out", "a"},
		{"hive", "invite", "--unknown"},
	} {
		if _, err := parseHive(args); err == nil {
			t.Fatalf("%v was accepted", args)
		}
	}
}
