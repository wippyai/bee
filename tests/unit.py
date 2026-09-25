"""Run every registered Lua test entry in four isolated, balanced processes."""
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
from pathlib import Path
import os
import re
import subprocess
import time

import yaml

from workspace import RUNTIME, ROOT, TEST_CACHE, fixture_workspace


# Case times from an unfiltered run; new entries get a small default weight.
SLOW = {
    "bee.harness.catalog:launch_test": 62.05,
    "bee.harness.catalog:permission_carrier_test": 56.65,
    "bee.harness.catalog:gateway_carrier_test": 26.52,
    "bee.harness.catalog:carrier_test": 17.55,
    "bee.placement.native:native_test": 10.62,
}
SHARDS = 4
LAUNCH_GROUP = {"bee.harness.catalog:launch_test", "bee.harness.catalog:permission_carrier_test"}


def test_entries(suites=None):
    entries = []
    for index in sorted((ROOT / "tests/lua").rglob("_index.yaml")):
        if suites is not None and index.relative_to(ROOT / "tests/lua").parts[0] not in suites:
            continue
        document = yaml.safe_load(index.read_text())
        entries.extend(document["namespace"] + ":" + entry["name"]
                       for entry in document.get("entries", []) if entry.get("meta", {}).get("type") == "test")
    assert entries and len(entries) == len(set(entries)), "Lua test IDs must be unique"
    # The upstream runner uses substring filters. Exact IDs are exclusive only
    # while no full test ID is contained in another full test ID.
    assert not any(left in right for left in entries for right in entries if left != right), \
        "A Lua test ID matches another entry's substring filter"
    return entries


def split(entries):
    groups = [[] for _ in range(SHARDS)]
    loads = [0.0] * SHARDS
    for entry in sorted(entries, key=lambda name: (-SLOW.get(name, .15), name)):
        # Permission exchange uses launch_test's host-selected setup in the
        # original ordered suite, so keep those entries in the same process.
        shard = 0 if entry in LAUNCH_GROUP else min(range(1, SHARDS), key=lambda index: (loads[index], index))
        groups[shard].append(entry)
        loads[shard] += SLOW.get(entry, .15)
    assert sorted(entry for group in groups for entry in group) == sorted(entries)
    assert all(groups), "Every Lua unit shard needs at least one entry"
    return groups


def environment(folder):
    # The carrier suite resolves its Claude fixture by name in the native host
    # PATH; every shard gets the binary and driver streams from its own copy.
    fixture_bin = folder / "fixtures/harness/bin"
    return {**os.environ,
            "WIPPY_CACHE_DIR": str(Path(os.environ.get("WIPPY_CACHE_DIR") or TEST_CACHE).resolve()),
            "BEE_FIXTURE_BIN": str(fixture_bin),
            "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers"),
            "PATH": str(fixture_bin) + os.pathsep + os.environ.get("PATH", "")}


def run_shard(index, folder, entries, timeout=None):
    started = time.monotonic()
    result = subprocess.run([
        str(RUNTIME), "test", "--host", "bee:terminal", "--override",
        "bee.hive.service:supervisor_service:lifecycle.auto_start=false",
        "test", *entries,
    ], cwd=folder, env=environment(folder), capture_output=True, text=True, timeout=timeout)
    output = result.stdout + result.stderr
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output)
    selected = re.search(r"(\d+) tests in \d+ suites", plain)
    cases = re.findall(r"(\d+) tests\s+[\d.]+s", plain)
    passed = re.findall(r"(\d+) passed\s+[\d.]+(?:ms|s)", plain)
    count = int(cases[-1]) if cases else int(passed[-1]) if passed else 0
    valid = result.returncode == 0 and selected is not None and int(selected.group(1)) == len(entries) and count > 0
    return index, entries, count, time.monotonic() - started, valid, result.returncode, output


def report_shard(result):
    index, selected_entries, cases, elapsed, valid, returncode, output = result
    print(f"Lua unit shard {index + 1}: {len(selected_entries)} entries, {cases} cases, {elapsed:.1f}s, {'pass' if valid else 'FAIL'}", flush=True)
    if not valid:
        print(f"Failed shard {index + 1} test IDs ({len(selected_entries)}); exit={returncode}:", flush=True)
        print("\n".join(selected_entries), flush=True)
        print(f"Failed shard {index + 1} complete output:\n{output}", flush=True)


def main():
    entries = test_entries()
    groups = split(entries)
    with ExitStack() as fixtures:
        folders = [fixtures.enter_context(fixture_workspace(managed_gateway=True)) for _ in groups]
        # Retain the unfiltered strict lint before any test process starts.
        subprocess.run([str(RUNTIME), "lint"], cwd=folders[0], check=True, env=environment(folders[0]))
        results = []
        with ThreadPoolExecutor(max_workers=SHARDS) as executor:
            jobs = [executor.submit(run_shard, index, folders[index], group)
                    for index, group in enumerate(groups)]
            for job in as_completed(jobs):
                result = job.result()
                report_shard(result)
                results.append(result)
    assert len(results) == SHARDS and all(result[4] for result in results), "A Lua unit shard failed"
    assert sum(len(result[1]) for result in results) == len(entries), "Lua test entry coverage changed"
    print(f"Lua unit: {len(entries)} entries, {sum(result[2] for result in results)} cases across {SHARDS} processes")


if __name__ == "__main__":
    main()
