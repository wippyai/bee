"""Managed OpenCode window acceptance with a fixture executable and no login.

The production OpenCode driver binding, window profile, admission, carrier,
placement and broker PTY path are the ones a real `bee opencode` window uses;
only the executable at the far end is the fixture, which draws a startup
marker and echoes input. No provider turn is submitted and no login happens.

Required environment: BEE_RUNTIME (the combined runtime binary) only. When
BEE_OPENCODE_BIN names the real opencode executable, a live smoke opens a
managed OpenCode window through the same path without logging in.
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent))
import workspace

ROOT = Path(__file__).resolve().parents[1]


def runtime_test(folder, environment, label):
    run = subprocess.run([str(workspace.RUNTIME), "test", "--host", "bee:terminal"],
                         cwd=folder, capture_output=True, text=True,
                         timeout=int(os.environ.get("BEE_OPENCODE_WINDOW_TIMEOUT", "120")), env=environment)
    out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
    if run.returncode != 0:
        for line in out.splitlines():
            if re.search(r"^\s+x |_test:\d+:|assertion failed", line):
                print(line[:800])
        sys.exit(run.returncode)
    if "PASSED" not in out:
        sys.exit("the managed OpenCode window proof did not pass for " + label)


def main():
    with workspace.fixture_workspace(unit_tests=False) as folder:
        tests = folder / "src/tests"
        shutil.copytree(ROOT / "tests/fixtures/managed_window_opencode", tests / "managed_window_opencode")
        path = tests / "managed_window_opencode/_index.yaml"
        document = yaml.safe_load(path.read_text())
        policy = next(e for e in document["entries"] if e["name"] == "policy")["data"]
        policy["executables"] = {"opencode": str(folder / "fixtures/harness/opencode/opencode")}
        policy["environment"] = {"BEE_FIXTURE_MARKER": "opencode-fixture"}
        path.write_text(yaml.safe_dump(document, sort_keys=False))
        # The window profile inherits the host user home, so OpenCode's login
        # evidence is $HOME/.local/share/opencode/auth.json. Point HOME at a
        # fixture home carrying an empty evidence file: the runtime checks the
        # file's existence and never reads it, so no credential is involved.
        home = folder / "provider-home"
        evidence = home / ".local/share/opencode/auth.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text("")
        environment = workspace.database_environment(folder, HOME=str(home))
        subprocess.run([str(workspace.RUNTIME), "lint", "--ns", "bee.managed.opencode.fixture"],
                       cwd=folder, env=environment, check=True, timeout=90)
        runtime_test(folder, environment, "the fixture executable")
    print("Managed OpenCode window: broker PTY startup, input, detach/rebind and one cancelled attempt "
          "receipt through the production binding passed; no provider turn and no login")


if __name__ == "__main__":
    main()
