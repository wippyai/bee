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
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import fixture_workspace, retain_test_suites  # noqa: E402
from unit import run_shard, split, test_entries  # noqa: E402

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
    entries = test_entries(SUITES)
    groups = split(entries)
    started = time.time()
    with ExitStack() as fixtures:
        folders = [fixtures.enter_context(fixture_workspace(managed_gateway=True)) for _ in groups]
        for folder in folders:
            retain_test_suites(folder / "src/tests", SUITES)
        with ThreadPoolExecutor(max_workers=len(groups)) as executor:
            jobs = [executor.submit(run_shard, index, folders[index], group,
                                    int(os.environ.get("BEE_MANAGED_LAUNCH_TIMEOUT", "900")))
                    for index, group in enumerate(groups)]
            results = [job.result() for job in as_completed(jobs)]
    outputs = []
    for index, selected, cases, elapsed, valid, output in sorted(results):
        out = re.sub(r"\x1b\[[0-9;]*m", "", output).replace("\r", "\n")
        print(f"Managed launch shard {index + 1}: {selected} entries, {cases} cases, {elapsed:.1f}s, {'pass' if valid else 'FAIL'}")
        if not valid:
            for line in out.splitlines():
                if re.search(r"^\s+x |_test:\d+:|assertion failed|failed to execute script", line):
                    print(line[:1800])
        outputs.append(out)
    combined = "\n".join(outputs)
    missing = [proof for proof in PROOFS if not re.search(r"^\s+o .*" + re.escape(proof), combined, re.M)]
    if missing:
        sys.exit("proofs that did not pass: " + "; ".join(missing))
    if not all(result[4] for result in results):
        sys.exit("managed launch suite failed")
    print(f"Managed launch: {len(entries)} entries with real Claude and Codex executables in {time.time() - started:.1f}s")


if __name__ == "__main__":
    main()
