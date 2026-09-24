"""Cross-session coordination acceptance with scripted fixture providers and no account.

Two managed agents of different drivers run in one workspace, each on its own
thread and reaching Bee only through its own gateway tools: a waiter under the
Claude driver and a sender under the Codex driver. The waiter finds the sender
through thread_sessions, registers thread_notify on it, tells it "ready" and
blocks in thread_wait. The sender waits for "ready" and answers "go ahead" to
the waiter's session with thread_message. The waiter wakes with the message,
and when the sender's turn ends the thread owner delivers a notice on the
waiter's own thread that its thread_wait sees.

Only the acceptance runs: every other test entry of the composed suites is
dropped, while their test-support entries (fixture policies, placement
fixture, managed listener) stay.

Required environment: BEE_RUNTIME (the combined runtime binary) only.
"""
import os
import re
import shutil
import subprocess
import sys
import time

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import RUNTIME, fixture_workspace  # noqa: E402

SUITES = ("placement", "harness", "driver", "credentials", "threads", "gateway", "managed")
TEST = "cross_session_acceptance_test"
ACCEPTANCE = "wakes a waiting session with a peer's message and tells it when the peer's turn ends"


def only_acceptance(tests):
    for child in tests.iterdir():
        if child.is_dir() and child.name not in SUITES:
            shutil.rmtree(child)
    for index in tests.rglob("_index.yaml"):
        document = yaml.safe_load(index.read_text())
        entries = document.get("entries", [])
        kept = [entry for entry in entries
                if (entry.get("meta") or {}).get("type") != "test" or entry.get("name") == TEST]
        if len(kept) != len(entries):
            document["entries"] = kept
            index.write_text(yaml.safe_dump(document, sort_keys=False))


def main():
    if not RUNTIME.is_file():
        sys.exit(f"BEE_RUNTIME must name the combined runtime binary; got {RUNTIME!r}")
    with fixture_workspace(managed_gateway=True) as folder:
        only_acceptance(folder / "src/tests")
        environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"),
                       "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers")}
        environment.pop("ANTHROPIC_API_KEY", None)
        environment.pop("OPENAI_API_KEY", None)
        started = time.time()
        run = subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal"], cwd=folder, capture_output=True, text=True,
                             timeout=int(os.environ.get("BEE_CROSS_SESSION_TIMEOUT", "600")), env=environment)
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        print(f"runtime test exit {run.returncode} after {time.time() - started:.1f} s")
        for line in out.splitlines():
            if re.search(r"^\s+x |_test:\d+:|assertion failed", line):
                print(line[:400])
        if run.returncode != 0:
            sys.exit(run.returncode)
        if not re.search(r"^\s+o .*" + re.escape(ACCEPTANCE), out, re.M):
            sys.exit("the cross-session acceptance did not pass: " + ACCEPTANCE)
        print("Cross-session threads (fixture providers, no account): a Claude-driver session finds a Codex-driver "
              "peer by session, the peer's message wakes its thread_wait, and a one-shot notice on its own thread "
              "tells it when the peer's turn ended")


if __name__ == "__main__":
    main()
