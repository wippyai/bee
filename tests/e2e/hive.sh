#!/usr/bin/env bash
# Two nodes in one hive and a display, driven through tmux against the built
# binary: the display switches to the other node, opens an app there, falls
# back to its own node when the other stops, and closes when its own stops.
set -euo pipefail

BEE="$(realpath "${1:-dist/bee}")"
ROOT="$(realpath "$(dirname "$0")/../..")/.wippy/e2e/hive"
SESSION="bee-e2e-$$"
REPO="$(realpath "$(dirname "$0")/../..")"
rm -rf "$ROOT"
mkdir -p "$ROOT/config" "$ROOT/alpha" "$ROOT/beta" "$ROOT/temporary" "$ROOT/home"
FIXTURE_HOME="$ROOT/home"
export BEE_FIXTURE_BIN="$REPO/tests/fixtures/harness/bin"
export BEE_FIXTURE_SESSION_STREAM="$REPO/tests/fixtures/hive/sessions-reply.jsonl"
export TMPDIR="$ROOT/temporary"
export TMUX_TMPDIR="$ROOT/temporary"
export XDG_CONFIG_HOME="$ROOT/config"

cleanup() {
    for pane in alpha beta display; do tmux kill-session -t "$SESSION-$pane" 2>/dev/null || true; done
}
trap cleanup EXIT

start() { # name folder command...
    local name="$1" folder="$2"; shift 2
    local node_command pane_command
    printf -v node_command '%q ' "$@"
    printf -v pane_command 'cd %q && %s; echo EXIT=$?; sleep 600' "$folder" "$node_command"
    tmux -f /dev/null new-session -d -s "$SESSION-$name" -x 120 -y 32 \
        env -i HOME="$FIXTURE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" TMPDIR="$TMPDIR" \
        BEE_FIXTURE_BIN="$BEE_FIXTURE_BIN" BEE_FIXTURE_SESSION_STREAM="$BEE_FIXTURE_SESSION_STREAM" \
        PATH="$BEE_FIXTURE_BIN:/usr/bin:/bin" /bin/bash -c "$pane_command"
}

screen() { tmux capture-pane -pt "$SESSION-$1"; }

# expect waits until pane shows text, up to 20 seconds.
expect() { # pane text step
    for _ in $(seq 1 200); do
        if screen "$1" | grep -qF -- "$2"; then return 0; fi
        sleep 0.1
    done
    echo "FAIL: $3: '$2' not shown on $1"; screen "$1"; exit 1
}

keys() { tmux send-keys -t "$SESSION-$1" "${@:2}"; }

env -i HOME="$FIXTURE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin "$BEE" hive init >/dev/null
start alpha "$ROOT/alpha" "$BEE" node
start beta "$ROOT/beta" "$BEE" node
expect alpha "is running" "alpha node starts"
expect beta "is running" "beta node starts"
start display "$ROOT/alpha" "$BEE"
expect display "Desktop 1 · alpha" "the display shows alpha's desktop"

keys display Escape F3
expect display " Bees " "the workspace menu opens"
expect display " beta " "the node strip names beta by its folder"
keys display Right
expect display "Enter show here (this display moves to beta)" "the menu browses beta's desktops"
keys display Enter
expect display "@ bee-" "the display shows beta's desktop"
expect display "Desktop 1 · beta" "beta's desktop works in beta's folder"

keys display F1
expect display "System" "the Start panel opens on beta"
keys display Down Enter
expect display "Keyboard help" "the System menu opens with Keyboard help, Library, Process Manager and Settings"
keys display End Enter
expect display "BEE SETTINGS" "Settings runs on beta in a window here"

for _ in $(seq 1 300); do
    if [ -f "$ROOT/alpha/hive-sdk-proof.json" ]; then break; fi
    sleep 0.1
done
python3 - "$ROOT/alpha/hive-sdk-proof.json" <<'PROOF'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
assert path.exists(), "FAIL: the application on alpha has no peer result"
result = json.loads(path.read_text())
assert result.get("ok") is True, result
assert result["source_node"] != result["destination_node"], result
assert result["source_pid"] != result["worker_pid"], result
assert result["configuration"] == "ci" and result["total"] == 18, result
print("PASS: app on alpha calls its copy on beta", json.dumps(result, sort_keys=True))
PROOF

for _ in $(seq 1 300); do
    if [ -f "$ROOT/alpha/hive-sessions-proof.json" ]; then break; fi
    sleep 0.1
done
python3 - "$ROOT/alpha/hive-sessions-proof.json" <<'PROOF'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
assert path.exists(), "FAIL: alpha has no Sessions peer result"
result = json.loads(path.read_text())
assert result.get("ok") is True, result
assert result["source_node"] != result["destination_node"], result
assert result["source_session"] != result["destination_session"], result
assert result["sender_session"] == result["source_session"], result
assert result["default_denied"] and result["durable_replay"], result
assert result["reply"] == "Fixture reply across bees", result
print("PASS: agent on alpha lists beta, sends and awaits its fixture reply", json.dumps(result, sort_keys=True))
PROOF

keys beta C-c
expect beta "EXIT=0" "beta stops cleanly"
expect display "Node bee-" "the display falls back to its own node and says which node stopped"
keys display Escape
expect display "Desktop 1 · alpha" "the display shows alpha's desktop again"

keys alpha C-c
expect alpha "EXIT=0" "alpha stops cleanly"
expect display "EXIT=1" "the display closes with its node"
screen display | grep -qF "stopped" || { echo "FAIL: the display does not say its node stopped"; screen display; exit 1; }
echo "PASS: hive e2e"
