"""Cross-session acceptance with scripted fixture providers and no account.

One case exercises shared-owner thread tools and notices. A second case uses
independent actors and threads to exercise discovery, accepted inbox sends,
deduplication, acknowledgment and cross-thread replies through their MCP tools.

Only the acceptance runs: every other test entry of the composed suites is
dropped, while their test-support entries (fixture policies, placement
fixture, managed listener) stay.

Required environment: BEE_RUNTIME (the combined runtime binary) only.
"""
import os
import re
import subprocess
import sys
import time

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import RUNTIME, fixture_workspace, retain_test_suites  # noqa: E402

SUITES = ("placement", "harness", "driver", "credentials", "threads", "gateway", "managed", "principals")
TEST = "cross_session_acceptance_test"
ACCEPTANCES = (
    "wakes a waiting session with a peer's message and tells it when the peer's turn ends",
    "delivers and replies between independent window actors without thread membership or polling",
    "answers a Codex-initiated inbox exchange without polling",
    "queues a busy Claude inbox and pushes its identified record between turns",
    "recovers an ambiguous Claude inbox write under a new carrier epoch",
    "polls an inbox item committed while its controller was down",
)


def only_acceptance(tests):
    retain_test_suites(tests, SUITES)
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
        for acceptance in ACCEPTANCES:
            if not re.search(r"^\s+o .*" + re.escape(acceptance), out, re.M):
                sys.exit("the cross-session acceptance did not pass: " + acceptance)
        print("Cross-session threads (fixture providers, no account): shared-owner notice, independent-action reply and Claude push recovery passed")


if __name__ == "__main__":
    main()
