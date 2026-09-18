"""Managed-launch acceptance: the placement, harness, driver, credential, thread
and gateway suites (with the test composition's loopback listener) against a
runtime that carries the managed-launch capabilities, with the real Claude and
Codex executables required so the authentication-path, permission-exchange and
gateway interoperability proofs run rather than report an open gate.

Required environment: BEE_RUNTIME (the combined runtime binary), BEE_CLAUDE_BIN
and BEE_CODEX_BIN (executables whose --version names Claude Code and Codex).
A missing or wrong value fails this target; it never reduces coverage.
"""
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import fixture_workspace  # noqa: E402

SUITES = ("placement", "harness", "driver", "credentials", "threads", "gateway", "managed")
PROOFS = (
    "resumes the real Codex session across two native attempts in one thread",
    "resumes the real Claude session across two native attempts in one thread",
    "selects the API-key path with the environment projection",
    "selects the API-key path through the runner with a generated configuration",
    "waits on a typed request, executes once on a correlated allow",
    "asks, answers and acknowledges allow, deny and expiry through placement",
    "recovers every boundary with one approval, one response and one effect against the executable",
    "Claude Code initializes, discovers and reads the bound thread through the gateway",
    "Codex initializes, discovers and reads the bound thread through the gateway",
    "Claude Code without the token variable authenticates nothing",
    "Codex without the token variable authenticates nothing",
    "Claude Code reports its hooks to the gateway under the hook credential",
    "Codex reports its hooks to the gateway under the hook credential",
)


def require_executable(name, marker):
    path = os.environ.get(name, "")
    if not path or not os.path.isfile(path):
        sys.exit(f"{name} must name an executable file; got {path!r}")
    version = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=60)
    if marker.lower() not in (version.stdout + version.stderr).lower():
        sys.exit(f"{name}={path} does not answer --version as {marker}: {(version.stdout + version.stderr).strip()[:200]!r}")
    return path


def main():
    runtime = os.environ.get("BEE_RUNTIME", "")
    if not runtime or not os.path.isfile(runtime):
        sys.exit(f"BEE_RUNTIME must name the combined runtime binary; got {runtime!r}")
    require_executable("BEE_CLAUDE_BIN", "Claude Code")
    require_executable("BEE_CODEX_BIN", "codex")
    with fixture_workspace(managed_gateway=True) as folder:
        tests = folder / "src/tests"
        for child in tests.iterdir():
            if child.is_dir() and child.name not in SUITES:
                shutil.rmtree(child)
        environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"), "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers")}
        environment.pop("ANTHROPIC_API_KEY", None)
        started = time.time()
        run = subprocess.run([runtime, "test", "--host", "bee:terminal"], cwd=folder, capture_output=True, text=True, timeout=int(os.environ.get("BEE_MANAGED_LAUNCH_TIMEOUT", "900")), env=environment)
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        print(f"runtime test exit {run.returncode} after {time.time() - started:.1f} s")
        for line in out.splitlines():
            if re.search(r"^\s+x |_test:\d+:|assertion failed|passed|tests ", line):
                print(line[:400])
        missing = [proof for proof in PROOFS if not re.search(r"^\s+o .*" + re.escape(proof), out, re.M)]
        if missing:
            sys.exit("proofs that did not pass: " + "; ".join(missing))
        if run.returncode != 0:
            sys.exit(run.returncode)
        print("Managed launch: placement, harness, driver, credential, thread and gateway suites with the real executables")


if __name__ == "__main__":
    main()
