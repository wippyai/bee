"""thread_launch acceptance with the scripted fixture provider and no account.

An orchestrator agent is admitted with thread_launch in its own launch policy,
which allow-lists exactly one worker definition. It calls thread_launch over
the real gateway; the owner operation starts the worker's own managed carrier
through the ordinary launch pipeline, the scripted worker reads its thread,
posts its answer and settles, and the orchestrator's thread_wait returns. The
worker's gateway tools are its own launch policy's, and lineage records the
orchestrator's action as the parent of the child's. A second case exercises the
managed-run tools: a managed orchestrator launches a Codex batch worker on a new
thread, registers thread_notify immediately from the returned attempt IDs,
wakes on thread_wait, reads the child's own
thread as member_thread, queries run_status, steers the child once, and cancels a
second worker with run_cancel.

Required environment: BEE_RUNTIME (the combined runtime binary) only.
"""
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import RUNTIME, fixture_workspace  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE = "starts an allow-listed child, delivers the brief, and waits for its answer and settlement"
RUN_ACCEPTANCE = "launches a Codex worker on a new thread, follows its run by notify and wait, steers it, and cancels a second worker"
TESTS = ("bee.harness.catalog:agent_launch_acceptance_test", "bee.harness.catalog:agent_run_acceptance_test")


def main():
    if not RUNTIME.is_file():
        sys.exit(f"BEE_RUNTIME must name the combined runtime binary; got {RUNTIME!r}")
    with fixture_workspace(managed_gateway=True) as folder:
        environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"),
                       "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers")}
        environment.pop("ANTHROPIC_API_KEY", None)
        started = time.time()
        run = subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal", "test", *TESTS],
                             cwd=folder, capture_output=True, text=True,
                             timeout=int(os.environ.get("BEE_THREAD_LAUNCH_TIMEOUT", "600")), env=environment)
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        print(f"runtime test exit {run.returncode} after {time.time() - started:.1f} s")
        for line in out.splitlines():
            if re.search(r"^\s+x |_test:\d+:|assertion failed", line):
                print(line[:400])
        if run.returncode != 0:
            sys.exit(run.returncode)
        for acceptance in (ACCEPTANCE, RUN_ACCEPTANCE):
            if not re.search(r"^\s+o .*" + re.escape(acceptance), out, re.M):
                sys.exit("the thread_launch acceptance did not pass: " + acceptance)
        print("Thread launch (fixture provider, no account): an orchestrator agent starts an "
              "allow-listed worker over the real gateway, the worker answers and settles, and the "
              "orchestrator's thread_wait returns its answer and terminal outcome; a managed orchestrator "
              "launches a Codex worker on a new thread, follows its run by notify and wait, steers it, and "
              "cancels a second worker")


if __name__ == "__main__":
    main()
