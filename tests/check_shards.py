# SPDX-License-Identifier: MIT
"""build/check_shards.py against fixture Makefiles: every step make check runs
belongs to exactly one shard, and the shards carry check's target variables."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "build/check_shards.py"

BASE = """\
check-shard-one check-shard-two check: export STORE = governance.db
check: alpha beta suite
suite: gamma delta
alpha beta gamma delta outside:
\t@true
"""


def run(directory, makefile, included="", names=False):
    (directory / "Makefile").write_text(makefile + "include extra.mk\n")
    (directory / "extra.mk").write_text(included)
    command = [sys.executable, str(SCRIPT), "--directory", str(directory)] + (["--names"] if names else [])
    return subprocess.run(command, capture_output=True, text=True)


def accepts(directory, label, makefile, included=""):
    result = run(directory, makefile, included, names=True)
    if result.returncode != 0:
        raise SystemExit(label + ": refused a complete shard set:\n" + result.stderr)
    return json.loads(result.stdout)


def refuses(directory, label, makefile, reason, included=""):
    result = run(directory, makefile, included)
    if result.returncode == 0:
        raise SystemExit(label + ": accepted an incomplete shard set")
    if reason not in result.stderr:
        raise SystemExit(label + ": expected " + repr(reason) + ", got:\n" + result.stderr)


(ROOT / ".wippy").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="check-shards-", dir=ROOT / ".wippy") as temporary:
    folder = Path(temporary)
    names = accepts(folder, "steps", BASE + "check-shard-one: alpha gamma\ncheck-shard-two: beta delta\n")
    if names != ["one", "two"]:
        raise SystemExit("shard names: " + repr(names))
    accepts(folder, "aggregate", BASE + "check-shard-one: alpha suite\ncheck-shard-two: beta\n")
    refuses(folder, "unsharded member", BASE + "check-shard-one: alpha gamma\ncheck-shard-two: delta\n",
            "make check runs beta, which no check shard runs")
    refuses(folder, "unsharded aggregate step", BASE + "check-shard-one: alpha gamma\ncheck-shard-two: beta\n",
            "make check runs delta, which no check shard runs")
    refuses(folder, "member joined elsewhere", BASE + "check-shard-one: alpha suite\ncheck-shard-two: beta\n",
            "make check runs epsilon, which no check shard runs", included="check: epsilon\nepsilon:\n\t@true\n")
    refuses(folder, "duplicate", BASE + "check-shard-one: alpha suite\ncheck-shard-two: beta gamma\n",
            "gamma runs in both check-shard-one and check-shard-two")
    refuses(folder, "outside step", BASE + "check-shard-one: alpha suite\ncheck-shard-two: beta outside\n",
            "check-shard-two runs outside, which make check does not run")
    refuses(folder, "check recipe", BASE + "check-shard-one: alpha suite\ncheck-shard-two: beta\n",
            "check has its own recipe", included="check:\n\t@true\n")
    refuses(folder, "shard recipe", BASE + "check-shard-one: alpha suite\ncheck-shard-two: beta\n\t@true\n",
            "check-shard-two must list check members and have no recipe")
    refuses(folder, "shard variables", BASE + "check-shard-one: alpha suite\ncheck-shard-three: beta\n",
            "check-shard-three sets [] but check sets")
    refuses(folder, "no shards", BASE.replace("check-shard-one check-shard-two check:", "check:"),
            "the Makefiles define no check-shard-* target")
print("Check shards: complete, exclusive and within make check; aggregates, members joined elsewhere, recipes and variables verified")
