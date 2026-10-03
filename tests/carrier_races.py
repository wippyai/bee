"""Retain event logs while repeating the complete make-test Lua shard layout."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import ExitStack
from pathlib import Path
import subprocess

from unit import report_shard, run_shard, split, test_entries
from workspace import ROOT, fixture_workspace, observe_carrier

RUNTIME_FILES = (
    "modules/harness/src/carrier/machine.lua",
    "modules/harness/src/service/process.lua",
    "modules/harness/src/types.lua",
    "modules/placement-native/src/service/service.lua",
    "modules/placement-native/src/service/runner.lua",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--baseline", help="Read runtime sources from this Git revision in disposable fixtures")
    parser.add_argument("--baseline-path", action="append", choices=RUNTIME_FILES, help="Limit the baseline substitution to this runtime source")
    parser.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    assert args.runs > 0
    args.logs.mkdir(parents=True, exist_ok=True)
    entries = test_entries()
    groups = split(entries, test_entries(resource="docker_daemon"))
    for iteration in range(1, args.runs + 1):
        with ExitStack() as fixtures:
            folders = [fixtures.enter_context(fixture_workspace(managed_gateway=True)) for _ in groups]
            if args.baseline:
                for name in args.baseline_path or RUNTIME_FILES:
                    source = subprocess.run(["git", "show", f"{args.baseline}:{name}"], cwd=ROOT,
                                            capture_output=True, text=True, check=True).stdout
                    if name.endswith("carrier/machine.lua"):
                        source = source.replace('    step(io, "committed")\n    if detected',
                                                '    step(io, "committed")\n    if message.eof then step(io, message.stream .. "_ended") end\n    if detected')
                    if name.endswith("service/service.lua"):
                        source = source.replace('local time = require("time")', 'local time = require("time")\nlocal ctx = require("ctx")')
                        begin = source.index("function M.close_stdin(")
                        end = source.index("-- reconcile:", begin)
                        closure = source[begin:end]
                        timer = 'local timer = time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")'
                        source = source.replace(closure, closure.replace(timer, '''local timer: Channel<time.Time>
    if ctx.get("bee.test.stdin.expired") == true then
        timer = channel.new(1)
        timer:send(time.now())
    else
        timer = time.after(tostring(protocol.FENCE_TIMEOUT_MS) .. "ms")
    end'''))
                    if name.endswith("service/runner.lua"):
                        source = source.replace("selected = channel.select(cases)",
                            'selected = channel.select(drain_armed and request.environment.PROBE_VALUE == "expire-pipe" and {drain_timer:case_receive()} or cases)')
                        gate = (folders[0] / name).read_text()
                        begin = gate.index('    if request.environment.PROBE_VALUE == "hold-retention" then')
                        end = gate.index('    local started, start_error = proc:start()', begin)
                        source = source.replace('    local started, start_error = proc:start()', gate[begin:end] + '    local started, start_error = proc:start()')
                    for folder in folders:
                        (folder / name).write_text(source)
                        if name == "modules/harness/src/service/process.lua":
                            observe_carrier(folder)
                        if name == "modules/placement-native/src/service/service.lua":
                            import yaml
                            index = folder / "modules/placement-native/src/service/_index.yaml"
                            document = yaml.safe_load(index.read_text())
                            modules = next(entry for entry in document["entries"] if entry["name"] == "service")["modules"]
                            if "ctx" not in modules:
                                modules.append("ctx")
                            index.write_text(yaml.safe_dump(document, sort_keys=False))
            results = []
            with ThreadPoolExecutor(max_workers=4) as executor:
                tasks = [executor.submit(run_shard, index, folders[index], group,
                                         log=args.logs / f"run-{iteration:02d}-shard-{index + 1}.log")
                         for index, group in enumerate(groups)]
                for task in as_completed(tasks):
                    result = task.result()
                    report_shard(result)
                    results.append(result)
            assert len(results) == 4 and all(result[4] for result in results), f"carrier load run {iteration} failed"
            print(f"Carrier load run {iteration}: {sum(result[2] for result in results)} cases; four complete shards green", flush=True)


if __name__ == "__main__":
    main()
