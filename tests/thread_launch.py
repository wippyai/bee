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
import shutil
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
LIVE_TEST = ("bee.harness.catalog:agent_launch_acceptance_test",)


def run_live_smokes():
    home = Path.home()
    logins = {
        "claude": home / ".claude/.credentials.json",
        "codex": home / ".codex/auth.json",
    }
    for provider, login_path in logins.items():
        if not login_path.is_file():
            print(f"Live {provider} orchestrator smoke: skipped (login file absent)")
            continue
        if not shutil.which(provider):
            print(f"Live {provider} orchestrator smoke: skipped (CLI absent)")
            continue
        with fixture_workspace(managed_gateway=True) as folder:
            # Pass only the home and command search path needed by the real CLI,
            # plus fixture settings. Provider/API key variables are not passed.
            environment = {
                "HOME": str(home),
                "PATH": os.environ.get("PATH", os.defpath),
                "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"),
                "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers"),
                "BEE_AMBIENT_LIVE_PROVIDER": provider,
                f"BEE_{provider.upper()}_BIN": str(Path(shutil.which(provider)).resolve()),
            }
            started = time.time()
            try:
                run = subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal", "test", *LIVE_TEST],
                                     cwd=folder, capture_output=True, text=True, timeout=600, env=environment)
            except subprocess.TimeoutExpired:
                sys.exit(f"Live {provider} orchestrator smoke failed (runtime timeout; output withheld)")
            out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
            passed = re.search(r"^\s+o .*" + re.escape(ACCEPTANCE), out, re.M)
            if run.returncode != 0 or not passed:
                safe_failure = "completion proof failed"
                for stage in ("host setup", "orchestrator completion", "orchestrator settlement", "child launch report",
                              "child identity", "child completion"):
                    if f"live {provider} smoke failed during {stage}" in out:
                        safe_failure = "acceptance stage " + stage
                        break
                sys.exit(f"Live {provider} orchestrator smoke failed (runtime exit {run.returncode}; "
                         f"{safe_failure}); output withheld")
            print(f"Live {provider} orchestrator smoke: a real batch worker completed through the provider login profile "
                  f"in {time.time() - started:.1f} s")


def main():
    if sys.argv[1:] not in ([], ["--live"]):
        sys.exit("usage: thread_launch.py [--live]")
    run_live = sys.argv[1:] == ["--live"]
    if not RUNTIME.is_file():
        sys.exit(f"BEE_RUNTIME must name the combined runtime binary; got {RUNTIME!r}")
    with fixture_workspace(managed_gateway=True) as folder:
        repository = folder / ".wippy/carrier-main"
        worktree = folder / ".wippy/carrier-worktree"
        subprocess.run(["git", "init", "--quiet", str(repository)], check=True)
        subprocess.run(["git", "-C", str(repository), "config", "user.name", "Bee Fixture"], check=True)
        subprocess.run(["git", "-C", str(repository), "config", "user.email", "bee-fixture@example.test"], check=True)
        (repository / "seed.txt").write_text("initial worktree commit\n")
        subprocess.run(["git", "-C", str(repository), "add", "seed.txt"], check=True)
        subprocess.run(["git", "-C", str(repository), "commit", "--quiet", "-m", "fixture base"], check=True)
        subprocess.run(["git", "-C", str(repository), "worktree", "add", "--quiet", "-b", "bee-fixture-worker", str(worktree)], check=True)
        environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"),
                       "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers"), "BEE_FIXTURE_GIT_COMMIT": "1",
                       "BEE_AMBIENT_LIVE_PROVIDER": "none"}
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
        subjects = subprocess.run(["git", "-C", str(worktree), "log", "--format=%s"], check=True,
                                  capture_output=True, text=True).stdout.splitlines()
        if "bee fixture commit" not in subjects:
            sys.exit("the confined Codex fixture worker did not commit in its Git worktree")
        dirty = subprocess.run(["git", "-C", str(worktree), "status", "--porcelain"], check=True,
                               capture_output=True, text=True).stdout
        if dirty:
            sys.exit("the confined Codex fixture worker left uncommitted worktree changes")
        print("Thread launch (fixture provider, no account): an orchestrator agent starts an "
              "allow-listed worker over the real gateway, the worker answers and settles, and the "
              "orchestrator's thread_wait returns its answer and terminal outcome; a managed orchestrator "
              "launches a confined Codex fixture worker that commits in a Git worktree, follows its run by "
              "notify and wait, steers it, and cancels a second worker")

    if run_live:
        run_live_smokes()


if __name__ == "__main__":
    main()
