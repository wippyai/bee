# SPDX-License-Identifier: MIT
"""Verify that the release check shards run exactly what `make check` runs.

Release CI runs `make check` as parallel `check-shard-<name>` jobs. Members join
`check` from many places in the Makefiles, so this reads make's own database and
proves that every step `make check` runs belongs to exactly one shard, that no
shard runs a step `make check` does not, and that every shard carries the target
variables `check` gives its members.

A step is a target with a recipe, or one without prerequisites. A target with
prerequisites and no recipe is an aggregate: it is covered by its steps.

    python3 build/check_shards.py [--directory DIR] [--names]

`--names` prints the shard names as a JSON list after the verification passes.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SHARD = "check-shard-"
GOAL = ".check-shards-database"
RULE = re.compile(r"^([^\s#:][^:]*?):(:?)(.*)$")
VARIABLE = re.compile(r"^\s*(?:export\s+|override\s+|private\s+)*[A-Za-z_][A-Za-z0-9_.-]*\s*(?:[:+?!]?=|::=)")


class Target:
    def __init__(self):
        self.prerequisites = []
        self.variables = []
        self.recipe = False


def database(directory):
    # A goal with neither prerequisites nor recipe: question mode prints the
    # database and runs nothing, not even recipes that invoke $(MAKE).
    result = subprocess.run(["make", "--no-print-directory", "-pq", "-f", "Makefile", "-f", "-", GOAL],
                            cwd=directory, input=GOAL + ":\n", capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit("make could not read the Makefiles:\n" + result.stderr)
    return result.stdout


def targets(text):
    lines = text.splitlines()
    try:
        start = lines.index("# Files")
    except ValueError:
        raise SystemExit("make printed no file database")
    table = {}
    block = []
    for line in lines[start + 1:] + [""]:
        if line.startswith("# files hash-table stats"):
            break
        if line.strip():
            block.append(line)
            continue
        if block and block[0] != "# Not a target:":
            for entry in block:
                if entry.startswith("#  recipe to execute"):
                    for name in rule_names(block):
                        table.setdefault(name, Target()).recipe = True
            for entry in block:
                match = RULE.match(entry)
                if not match:
                    continue
                name, rest = match.group(1).strip(), match.group(3)
                target = table.setdefault(name, Target())
                if VARIABLE.match(rest):
                    target.variables.append(rest.strip())
                else:
                    ordinary = rest.split("|", 1)[0].split()
                    target.prerequisites.extend(item for item in ordinary if item not in target.prerequisites)
        block = []
    return table


def rule_names(block):
    return [match.group(1).strip() for match in map(RULE.match, block) if match]


def steps(table, name, seen=()):
    if name in seen:
        raise SystemExit("prerequisite cycle through " + name)
    target = table.get(name)
    if target is None or target.recipe or not target.prerequisites:
        return [name]
    found = []
    for prerequisite in target.prerequisites:
        for step in steps(table, prerequisite, seen + (name,)):
            if step not in found:
                found.append(step)
    return found


def verify(table):
    problems = []
    check = table.get("check")
    if check is None:
        return ["the Makefiles define no check target"], []
    if check.recipe:
        problems.append("check has its own recipe; every check step must be a named member a shard can run")
    shards = sorted(name[len(SHARD):] for name in table if name.startswith(SHARD))
    if not shards:
        problems.append("the Makefiles define no " + SHARD + "* target")
    required = steps(table, "check")
    owner = {}
    for shard in shards:
        target = table[SHARD + shard]
        if target.recipe or not target.prerequisites:
            problems.append(SHARD + shard + " must list check members and have no recipe")
        if sorted(target.variables) != sorted(check.variables):
            problems.append(SHARD + shard + " sets " + repr(sorted(target.variables)) + " but check sets " + repr(sorted(check.variables)))
        for step in steps(table, SHARD + shard):
            if step not in required:
                problems.append(SHARD + shard + " runs " + step + ", which make check does not run")
            elif step in owner:
                problems.append(step + " runs in both " + SHARD + owner[step] + " and " + SHARD + shard)
            else:
                owner[step] = shard
    for step in required:
        if step not in owner:
            problems.append("make check runs " + step + ", which no check shard runs")
    return problems, shards


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--directory", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--names", action="store_true")
    options = parser.parse_args()
    problems, shards = verify(targets(database(options.directory)))
    if problems:
        for problem in problems:
            print("check shards: " + problem, file=sys.stderr)
        return 1
    if options.names:
        print(json.dumps(shards))
    return 0


if __name__ == "__main__":
    sys.exit(main())
