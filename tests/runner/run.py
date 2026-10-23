"""Run native Wippy suite selections in independent, duration-balanced workspaces."""
import argparse
from copy import deepcopy
from contextlib import ExitStack
import fcntl
import codecs
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import uuid

import yaml

from . import budgets
from . import docker_fixture

TESTS = Path(__file__).resolve().parents[1]
REPO = TESTS.parent
DURATIONS = Path(__file__).parent / "data/durations.json"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PROGRESS = re.compile(r"^\s+\S+\s+(\S+)\s+\((\d+)/(\d+)\)\s+(\S+)")
CASE = re.compile(r"^\s+[ox] (.+?)\s+(<1ms|[\d.]+(?:ms|s))$")
SUMMARY = re.compile(r"^\s+(\d+) (?:passed|tests)(?:\s+(\d+) failed)?(?:\s+(\d+) skipped)?\s+(<1ms|[\d.]+(?:ms|s))$", re.M)


def seconds(value):
    return .0005 if value == "<1ms" else float(value[:-2]) / 1000 if value.endswith("ms") else float(value[:-1])


def entries():
    found = {}
    for index in sorted((TESTS / "lua").rglob("_index.yaml")):
        document = yaml.safe_load(index.read_text())
        for entry in document.get("entries", []):
            if entry.get("meta", {}).get("type") == "test":
                identity = document["namespace"] + ":" + entry["name"]
                found[identity] = (entry.get("meta", {}).get("suite", "other"),
                                   index.parent / entry["source"].removeprefix("file://"),
                                   entry.get("meta", {}).get("order", 0))
    return found


class Progress:
    def __init__(self, selected):
        self.candidates = {}
        for identity in sorted(selected, key=lambda name: (selected[name][0], selected[name][2], name)):
            self.candidates.setdefault((selected[identity][0], identity.split(":")[1]), []).append(identity)
        self.positions = {}
        self.current = self.previous = None

    def advance(self, line):
        progress = PROGRESS.match(line)
        if not progress:
            return False
        suite, number, _, name = progress.groups()
        key = (suite, number, name)
        if key == self.previous:
            return False
        names = self.candidates.get((suite, name), [])
        position = self.positions.get((suite, name), 0)
        self.current = names[position] if position < len(names) else None
        self.positions[suite, name] = position + 1
        self.previous = key
        return True


class Timeline:
    """Measure entries from their first progress event through runner completion."""
    def __init__(self, selected):
        self.progress = Progress(selected)
        self.started = None
        self.durations = {}

    def finish(self, now):
        if self.started is not None and self.progress.current:
            self.durations[self.progress.current] = now - self.started
        self.started = None

    def line(self, line, now):
        line = ANSI.sub("", line)
        progress = PROGRESS.match(line)
        if progress:
            suite, number, _, name = progress.groups()
            if self.progress.previous != (suite, number, name):
                self.finish(now)
                self.progress.advance(line)
                self.started = now
        elif re.match(r"^\s+[ox] \S+ \(\d+\)", line) or SUMMARY.fullmatch(line):
            self.finish(now)


def measure(output, selected):
    """Associate the runner's per-entry progress with each case duration."""
    clean = ANSI.sub("", output).replace("\r", "\n")
    filters = re.search(r"^  Filter: (.+)$", clean, re.M)
    if filters:
        patterns = filters[1].split(", ")
        selected = {name: entry for name, entry in selected.items() if any(pattern in name for pattern in patterns)}
    progress = Progress(selected)
    measured, cases = {}, []
    for line in clean.splitlines():
        if PROGRESS.match(line):
            progress.advance(line)
            continue
        case = CASE.match(line)
        if case and progress.current and not re.search(r" \(\d+\) (?:\d+/\d+|\d+ failed)", case[1]):
            elapsed = seconds(case[2])
            measured[progress.current] = measured.get(progress.current, 0) + elapsed
            cases.append({"suite": progress.current, "test": case[1], "seconds": elapsed})
    return clean, measured, cases



def entry_durations(timeline, cases, completed=None):
    values = {name: max(timeline.get(name, 0), cases.get(name, 0))
              for name in timeline.keys() | cases.keys()}
    values.update(completed or {})
    return values

def balance(selected, durations, count):
    docker = [name for name, entry in selected.items() if entry[0] == "bee_docker"]
    others = {name: entry for name, entry in selected.items() if name not in docker}
    if docker and count > 1:
        return [sorted(docker)] + (balance(others, durations, count - 1) if others else [])
    groups = [[] for _ in range(min(count, len(selected)))]
    weights = [0.] * len(groups)
    parents = {name: name for name in selected}
    def parent(name):
        while parents[name] != name:
            name = parents[name]
        return name
    for name in selected:
        for other in selected:
            if name != other and name in other:
                parents[parent(other)] = parent(name)
    bundles = {}
    for name in selected:
        bundles.setdefault(parent(name), []).append(name)
    for bundle in sorted(bundles.values(), key=lambda names: (-sum(durations.get(name, 1.) for name in names), min(names))):
        target = min(range(len(groups)), key=lambda index: (weights[index], index))
        groups[target].extend(sorted(bundle))
        weights[target] += sum(durations.get(name, 1.) for name in bundle)
    return [group for group in groups if group]


def declare_deadlines(document, costs=None, suite_limits=None):
    """Use measured entry costs without widening the previous 30s fallback."""
    changed = False
    for item in document.get("entries", []):
        meta = item.get("meta", {})
        if meta.get("type") != "test":
            continue
        identity = document["namespace"] + ":" + item["name"] if "namespace" in document else item["name"]
        deadline = f"{budgets.entry(meta, identity, costs or {}):g}s"
        if meta.get("timeout") != deadline:
            meta["timeout"] = deadline
            changed = True
        if suite_limits and meta.get("suite", "other") in suite_limits:
            meta["suite_timeout"] = f"{suite_limits[meta.get('suite', 'other')]}s"
            changed = True
    return changed


def select_shards(groups, shard):
    """Keep global shard numbers when running one CI matrix selection."""
    if shard is not None and not 1 <= shard <= len(groups):
        raise ValueError(f"--shard must be between 1 and {len(groups)}")
    return [(number, group) for number, group in enumerate(groups, 1)
            if shard is None or number == shard]


def wrap_suites(document, source):
    generated = []
    for entry in document.get("entries", []):
        if entry.get("meta", {}).get("type") != "test":
            continue
        body = deepcopy(entry)
        body["name"] += "__body"
        body["meta"]["type"] = "test_support"
        identity = document["namespace"] + ":" + entry["name"]
        entry["meta"]["hygiene_body"] = document["namespace"] + ":" + body["name"]
        entry["source"] = source
        entry["method"] = "run"
        entry["modules"] = ["funcs", "process", "registry", "ctx", "json", "time", "system"]
        entry["imports"] = {"bounds": "bee.drivers.values:bounds"}
        entry.pop("security", None)
        generated.append(body)
    document["entries"].extend(generated)
    return bool(generated)

def copy_workspace(root, address, identities=()):
    root.mkdir()
    for name in ("lua", "fixtures"):
        shutil.copytree(TESTS / name, root / name)
    # The drivers module owns its recorded CLI streams; Bee's suites read them too.
    shutil.copytree(REPO / "drivers/test/fixtures/drivers", root / "fixtures/drivers")
    composition = root / ".wippy/composition"
    shutil.copytree(TESTS / ".wippy/composition", composition)
    drivers_composition = root / ".wippy/composition-drivers"
    shutil.copytree(TESTS / ".wippy/composition-drivers", drivers_composition)
    shutil.copy2(TESTS / "wippy.lock", root / "wippy.lock")
    shutil.copy2(TESTS / ".wippy.yaml", root / ".wippy.yaml")
    (root / ".wippy/vendor").symlink_to(TESTS / ".wippy/vendor", target_is_directory=True)
    original = str(TESTS / "fixtures")
    costs = budgets.load()
    indices = list((root / "lua").rglob("_index.yaml")) + list(composition.rglob("_index.yaml")) + list(drivers_composition.rglob("_index.yaml"))
    suite_limits = budgets.suites([yaml.safe_load(index.read_text()) for index in indices], set(identities), costs)
    for index in indices:
        value = index.read_text()
        rewritten = value.replace(original, str(root / "fixtures"))
        document = yaml.safe_load(rewritten)
        changed = declare_deadlines(document, costs, suite_limits)
        if index.is_relative_to(root / "lua"):
            changed = wrap_suites(document, "file://" + os.path.relpath(root / "lua/support/hygiene/wrapper.lua", index.parent)) or changed
        if changed:
            rewritten = yaml.safe_dump(document, sort_keys=False)
        if rewritten != value:
            index.write_text(rewritten)
    for path, name, field in (("src/_index.yaml", "gateway_listener", "addr"),
                              ("src/gateway/api/_index.yaml", "gateway_endpoint", "data")):
        index = composition / path
        document = yaml.safe_load(index.read_text())
        entry = next(entry for entry in document["entries"] if entry["name"] == name)
        if field == "data":
            entry[field]["address"] = address
        else:
            entry[field] = address
        index.write_text(yaml.safe_dump(document, sort_keys=False))
    index = composition / "src/gateway/security/_index.yaml"
    document = yaml.safe_load(index.read_text())
    policy = next(entry for entry in document["entries"] if entry["name"] == "readiness_policy")
    policy["policy"]["expression"] = ('(action == "http_client.private_ip" && resource == "127.0.0.1") || '
                                        f'(action == "http_client.request" && resource == "http://{address}/ready")')
    index.write_text(yaml.safe_dump(document, sort_keys=False))
    fixture = root / ".wippy/fixture"
    for directory in ("home/.claude", "tmp", "bin"):
        (fixture / directory).mkdir(parents=True)
    (fixture / "home/.claude/.credentials.json").touch()
    (fixture / "bin/absolute-claude").symlink_to(root / "fixtures/harness/bin/claude")
    return fixture


def workspace(root, address, identities=()):
    with (TESTS / ".wippy/composition.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        return copy_workspace(root, address, identities)


def run_shard(number, identities, run_root, toolchain, cores, count, discovered, reservation, lua_cache, lua_cache_mode='readwrite'):
    started = time.monotonic()
    root = run_root / f"shard-{number:02d}"
    with reservation:
        address = f"127.0.0.1:{reservation.getsockname()[1]}"
        fixture = workspace(root, address, identities)
    home = fixture / "home"
    binaries = root / "fixtures/harness/bin"
    environment = {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
                   "XDG_DATA_HOME": str(home / ".local/share"), "XDG_CACHE_HOME": str(home / ".cache"),
                   "WIPPY_CACHE_DIR": str(REPO / ".wippy/cache/tests"), "TMPDIR": str(fixture / "tmp"),
                   "LANG": "C.UTF-8", "NO_COLOR": "", "PATH": f"{binaries}:{fixture / 'bin'}:/usr/bin:/bin",
                   "BEE_FIXTURE_BIN": str(binaries), "BEE_FIXTURE_STREAMS": str(root / "fixtures/drivers"),
                   "BEE_FIXTURE_HOOK_COMMAND": str(binaries / "gateway-client"), "BEE_AMBIENT_LIVE_PROVIDER": "none",
                   "CLAUDE_CONFIG_DIR": str(fixture / "shell/claude"), "CODEX_HOME": str(fixture / "shell/codex"),
                   "ANTHROPIC_API_KEY": "fixture-shell-value-not-a-key", "GOMAXPROCS": str(min(4, max(2, math.ceil(cores / count))))}
    command = [str(toolchain), "test", "--memory-limit", "1G", "--host", "bee:terminal",
               "--set", "lua.cache.dir=" + str(lua_cache.resolve()),
               "--set", "lua.cache.mode=" + lua_cache_mode,
               "test", *sorted(identities)]
    command = [sys.executable, str(TESTS / "lua/support/hygiene/process_guard.py"), "run", *command]
    log = root / "output.log"
    timeline = Timeline({name: discovered[name] for name in identities})
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    pending = ""
    with log.open("wb") as output:
        process = subprocess.Popen(command, cwd=root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while chunk := process.stdout.read1(65536):
            output.write(chunk)
            output.flush()
            fragments = re.split(r"[\r\n]", pending + decoder.decode(chunk))
            pending = fragments.pop()
            now = time.monotonic()
            for line in fragments:
                timeline.line(line, now)
        code = process.wait()
    timeline.finish(time.monotonic())
    clean, case_durations, cases = measure(log.read_text(), {name: discovered[name] for name in identities})
    summaries = SUMMARY.findall(clean)
    counts = tuple(int(value or 0) for value in summaries[-1][:3]) if summaries else (0, 0, 0)
    failure = clean.split("  Failures\n", 1)[1].split("\n  FAILED", 1)[0].strip() if "  Failures\n" in clean else ""
    measured = entry_durations(timeline.durations, case_durations)
    completed = {}
    breakdown = {}
    database = root / ".wippy/hygiene.db"
    if database.exists():
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
            if connection.execute("SELECT 1 FROM sqlite_master WHERE name='bee_test_suite_timings'").fetchone():
                completed = dict(connection.execute("SELECT entry_id, seconds FROM bee_test_suite_timings"))
                measured.update(completed)
                columns = {row[1] for row in connection.execute("PRAGMA table_info(bee_test_suite_timings)")}
                if 'body_seconds' in columns:
                    breakdown = {name: {"body": body, "hygiene": hygiene} for name, body, hygiene in
                                 connection.execute("SELECT entry_id, body_seconds, hygiene_seconds FROM bee_test_suite_timings")}
    if code == 0 and any(name not in completed for name in identities):
        code = 1
        failure = "missing suite hygiene completion"
    (root / "timings.json").write_text(json.dumps(measured, indent=2) + "\n")
    elapsed = time.monotonic() - started
    print(f"Shard {number:02d}: {counts[0]} passed, {counts[1]} failed, {elapsed:.1f}s ({log.relative_to(REPO)})", flush=True)
    if code and not failure:
        failure = clean[-8000:]
    return {"shard": number, "code": code, "counts": counts, "seconds": elapsed, "durations": measured,
            "case_seconds": case_durations, "cases": cases, "timing_breakdown": breakdown,
            "failure": failure, "summary_found": bool(summaries)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wippy", type=Path, default=REPO / ".wippy/bin/wippy")
    parser.add_argument("--lua-cache", type=Path, default=REPO / ".wippy/lua-cache")
    parser.add_argument("--lua-cache-mode", choices=('readonly', 'readwrite'), default='readwrite')
    parser.add_argument("--shards", type=int, default=max(1, len(os.sched_getaffinity(0)) // 4))
    parser.add_argument("--shard", type=int, help="Run only this 1-based shard of the full duration-balanced plan")
    parser.add_argument("--tests", nargs="*", default=[])
    parser.add_argument("--measure", type=Path, nargs="+")
    parser.add_argument("--update-durations", action="store_true")
    args = parser.parse_args()
    discovered = entries()
    durations = json.loads(DURATIONS.read_text()) if DURATIONS.exists() else {}
    if args.measure:
        cases = []
        for log in args.measure:
            _, values, measured_cases = measure(log.read_text(), discovered)
            timing = log.with_name("timings.json")
            if timing.exists():
                values = json.loads(timing.read_text())
            durations.update(values)
            cases.extend(measured_cases)
        DURATIONS.write_text(json.dumps(dict(sorted(durations.items())), indent=2) + "\n")
        print("Slowest 30 suites:")
        for name, elapsed in sorted(durations.items(), key=lambda item: -item[1])[:30]:
            print(f"{elapsed:8.3f}s {name}")
        print("Slowest 30 tests:")
        for case in sorted(cases, key=lambda case: -case["seconds"])[:30]:
            print(f"{case['seconds']:8.3f}s {case['suite']} > {case['test']}")
        return 0
    if args.shards < 1:
        parser.error("--shards must be positive")
    selected = {}
    for pattern in args.tests or [""]:
        matched = {name: value for name, value in discovered.items() if pattern in name}
        if not matched:
            parser.error(f"no test entry matches {pattern!r}")
        selected.update(matched)
    groups = balance(selected, durations, args.shards)
    try:
        active = select_shards(groups, args.shard)
    except ValueError as error:
        parser.error(str(error))
    active_entries = {name for _, group in active for name in group}
    indices = {discovered[name][1].parent / '_index.yaml' for name in active_entries}
    fixture_seconds = docker_fixture.prepare([yaml.safe_load(index.read_text()) for index in sorted(indices)], active_entries)
    run_root = TESTS / ".wippy/runs" / uuid.uuid4().hex
    run_root.mkdir(parents=True)
    (run_root / "plan.json").write_text(json.dumps(groups, indent=2) + "\n")
    started = time.monotonic()
    print(f"Running {sum(len(group) for _, group in active)} suites in {len(active)} isolated shards "
          f"from the {len(groups)}-shard plan; load {os.getloadavg()[0]:.1f}", flush=True)
    results = []
    with ExitStack() as reservations, ThreadPoolExecutor(max_workers=len(active)) as pool:
        ports = []
        for _ in active:
            port = reservations.enter_context(socket.socket())
            port.bind(("127.0.0.1", 0))
            ports.append(port)
        futures = {pool.submit(run_shard, index, group, run_root, args.wippy.resolve(),
                               len(os.sched_getaffinity(0)), len(active), discovered, port, args.lua_cache, args.lua_cache_mode): index
                   for (index, group), port in zip(active, ports)}
        completed = {}
        for future in as_completed(futures):
            completed[futures[future]] = future.result()
        results = [completed[index] for index in sorted(completed)]
    elapsed = time.monotonic() - started
    (run_root / "results.json").write_text(json.dumps({"fixture_seconds": fixture_seconds, "seconds": elapsed, "results": results}, indent=2) + "\n")
    if any(result["failure"] for result in results):
        print("\n  Failures\n")
    for result in results:
        if result["failure"]:
            print(result["failure"])
    passed, failed, skipped = (sum(result["counts"][index] for result in results) for index in range(3))
    bad = any(result["code"] or result["counts"][1] or not result["summary_found"] for result in results)
    print("FAILED" if bad else "PASSED")
    print(f"{passed} passed" + (f"  {failed} failed" if failed else "") +
          (f"  {skipped} skipped" if skipped else "") + f"  {elapsed:.1f}s", flush=True)
    if args.update_durations and not bad:
        for result in results:
            durations.update(result["durations"])
        DURATIONS.write_text(json.dumps(dict(sorted(durations.items())), indent=2) + "\n")
    return int(bad)


if __name__ == "__main__":
    raise SystemExit(main())
