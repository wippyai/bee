"""Repeat the complete Lua shard layout, retaining every shard's output."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
import os
from pathlib import Path
import tempfile

from unit import SHARDS, report_shard, run_shard, split, test_entries
from workspace import ROOT, fixture_workspace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=10)
    arguments = parser.parse_args()
    if not 1 <= arguments.runs <= 10:
        parser.error("--runs must be between 1 and 10")
    jobs = int(os.environ.get("BEE_TEST_JOBS", SHARDS))
    if not 1 <= jobs <= SHARDS:
        parser.error(f"BEE_TEST_JOBS must be between 1 and {SHARDS}")
    parent = ROOT / ".wippy/gateway-race"
    parent.mkdir(parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
    print(f"Gateway race logs: {logs}", flush=True)
    entries = test_entries()
    groups = split(entries, test_entries(resource="docker_daemon"))
    failed_rounds = []
    for iteration in range(1, arguments.runs + 1):
        with ExitStack() as fixtures:
            folders = [fixtures.enter_context(fixture_workspace(managed_gateway=True)) for _ in groups]
            results = []
            with ThreadPoolExecutor(max_workers=jobs) as executor:
                futures = [executor.submit(run_shard, index, folders[index], group)
                           for index, group in enumerate(groups)]
                for future in as_completed(futures):
                    result = future.result()
                    (logs / f"round-{iteration:02d}-shard-{result[0] + 1}.log").write_text(result[6])
                    report_shard(result)
                    results.append(result)
        if len(results) != SHARDS or not all(result[4] for result in results):
            failed_rounds.append(iteration)
            print(f"Gateway race round {iteration} failed; complete logs: {logs}", flush=True)
        print(f"Gateway race round {iteration}/{arguments.runs}: {len(entries)} entries, "
              f"{sum(result[2] for result in results)} cases", flush=True)
    if failed_rounds:
        raise SystemExit(f"Gateway race failed rounds: {failed_rounds}; complete logs: {logs}")


if __name__ == "__main__":
    main()
