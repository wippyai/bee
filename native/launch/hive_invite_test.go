// SPDX-License-Identifier: MIT

package launch

import "testing"

func TestInviteHintNamesTheJoinCommandForTheOtherNode(t *testing.T) {
	line := "bee-hive://id:secret@127.0.0.1:1/bee-owner-a?key=k"
	want := "Single use. On the node that joins, with its Bee stopped, run:\n  bee hive join " + line + "\n"
	if got := inviteHint(line); got != want {
		t.Fatalf("hint = %q, want %q", got, want)
	}
}
