# SPDX-License-Identifier: MIT
"""Run every verified make-check shard concurrently with separate pack output."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import check_shards

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / ".wippy/check-parallel"


def run(shard):
    output = RESULTS / shard
    output.mkdir(parents=True, exist_ok=True)
    log = output / "check.log"
    manifest = output / "bee.bundle.build.json"
    started = time.monotonic()
    with log.open("w") as stream:
        process = subprocess.Popen([
            "make", "--no-print-directory", "check-shard-" + shard,
            "BEE_BUNDLE_MANIFEST=" + str(manifest),
        ], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        _, status, usage = os.wait4(process.pid, 0)
        process.returncode = os.waitstatus_to_exitcode(status)
    return shard, process.returncode, time.monotonic() - started, usage.ru_utime + usage.ru_stime, log


def failure_tail(log):
    lines = log.read_text(errors="replace").splitlines()[-25:]
    plain = [re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line)[-220:] for line in lines]
    return "\n".join(plain)[-3500:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=4)
    options = parser.parse_args()
    if options.jobs < 1:
        parser.error("--jobs must be positive")
    table = check_shards.targets(check_shards.database(ROOT))
    problems, shards = check_shards.verify(table)
    if problems:
        for problem in problems:
            print("check shards: " + problem, file=sys.stderr)
        return 1
    started = time.monotonic()
    results = []
    with ThreadPoolExecutor(max_workers=options.jobs) as executor:
        jobs = [executor.submit(run, shard) for shard in shards]
        for job in as_completed(jobs):
            result = job.result()
            shard, status, wall, cpu, log = result
            print(f"{shard}: {'PASS' if status == 0 else 'FAIL'} {wall:.1f}s wall {cpu:.1f}s CPU ({log.relative_to(ROOT)})", flush=True)
            if status:
                print(failure_tail(log), flush=True)
            results.append(result)
    print(f"Parallel check: {len(results)} shards, {time.monotonic()-started:.1f}s wall, "
          f"{sum(result[3] for result in results):.1f}s CPU", flush=True)
    return int(any(result[1] for result in results))


if __name__ == "__main__":
    sys.exit(main())
