"""Managed-launch acceptance with no provider account: the fixture Claude
protocol binary and a captured stream-json-2 transcript stand in for the
real Claude executable, so the launch definition, admission, carrier,
placement and gateway suites all run against the identical production
driver binding and launch pipeline real accounts use. Only the executable
at the far end is synthetic.

Proves two things `make managed-launch-check` cannot prove without
BEE_CLAUDE_BIN/BEE_CODEX_BIN:
  1. a managed agent's native window really reaches a real terminal (a real
     OS process owning a real PTY), with launch evidence left on the thread;
  2. a real driven turn through the real admission/carrier path leaves its
     observations (turn.request, settlement) on the thread.

Required environment: BEE_RUNTIME (the combined runtime binary) only.
"""
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import RUNTIME, fixture_workspace  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SUITES = ("placement", "harness", "driver", "credentials", "threads", "gateway", "managed")
TERMINAL_PROOF = "opens a real native terminal for the fixture provider and leaves launch evidence on the thread"
TURN_PROOF = "starts the carrier to settlement and a retried start recovers the same attempt"


def main():
    if not RUNTIME.is_file():
        sys.exit(f"BEE_RUNTIME must name the combined runtime binary; got {RUNTIME!r}")
    with fixture_workspace(managed_gateway=True) as folder:
        tests = folder / "src/tests"
        for child in tests.iterdir():
            if child.is_dir() and child.name not in SUITES:
                shutil.rmtree(child)
        shutil.copytree(ROOT / "tests/fixtures/managed_launch_fixture", tests / "managed_launch_fixture")
        path = tests / "managed_launch_fixture/_index.yaml"
        document = yaml.safe_load(path.read_text())
        policy = next(e for e in document["entries"] if e["name"] == "policy")["data"]
        policy["executables"] = {"claude": str(folder / "fixtures/harness/bin/claude")}
        policy["environment"] = {"BEE_FIXTURE_STREAM": str(folder / "fixtures/drivers/claude/stream-json-2/plain.jsonl"), "BEE_FIXTURE_LINGER": "30"}
        path.write_text(yaml.safe_dump(document, sort_keys=False))
        environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"), "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers")}
        environment.pop("ANTHROPIC_API_KEY", None)
        started = time.time()
        run = subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal"], cwd=folder, capture_output=True, text=True,
                              timeout=int(os.environ.get("BEE_MANAGED_LAUNCH_FIXTURE_TIMEOUT", "300")), env=environment)
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        print(f"runtime test exit {run.returncode} after {time.time() - started:.1f} s")
        for line in out.splitlines():
            if re.search(r"^\s+x |_test:\d+:|assertion failed", line):
                print(line[:400])
        terminal_line = next((line for line in out.splitlines() if re.match(r"^\s+o .*" + re.escape(TERMINAL_PROOF), line)), None)
        turn_line = next((line for line in out.splitlines() if re.match(r"^\s+o .*" + re.escape(TURN_PROOF), line)), None)
        if run.returncode != 0:
            sys.exit(run.returncode)
        if not terminal_line:
            sys.exit("the fixture-provider native-terminal proof did not pass: " + TERMINAL_PROOF)
        if not turn_line:
            sys.exit("the fixture-provider driven-turn proof did not pass: " + TURN_PROOF)
        print(terminal_line.strip())
        print(turn_line.strip())
        print("Managed launch (fixture provider, no account): launch definition, admission, carrier, placement and gateway "
              "reach a real native terminal and a real driven turn's observations land on the thread")


if __name__ == "__main__":
    main()
