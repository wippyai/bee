#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Load-aware standalone boot measurement; retained evidence lives in .wippy."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = ("fresh", "attach", "warm", "upgrade")
TARGETS_MS = {"attach": 300, "warm": 1000}


def eligible(load, cpus, nice, max_load):
    return cpus > 0 and nice == 0 and all(value / cpus <= max_load for value in load)


def compare(baseline, current, tolerance):
    if baseline["machine"] != current["machine"]:
        return ["baseline belongs to a different machine class"]
    failures = []
    for scenario in SCENARIOS:
        before = baseline["medians_ms"].get(scenario)
        after = current["medians_ms"].get(scenario)
        if before is None:
            failures.append(f"baseline missing scenario: {scenario}")
        elif after is None:
            failures.append(f"missing scenario: {scenario}")
        elif not all(isinstance(value, (int, float)) and math.isfinite(value) and value > 0 for value in (before, after)):
            failures.append(f"{scenario}: invalid timing")
        elif after > before * (1 + tolerance):
            failures.append(f"{scenario}: {after:.1f} ms exceeds baseline {before:.1f} ms + {tolerance:.0%}")
    return failures


def machine():
    cpu = platform.processor()
    if Path("/proc/cpuinfo").exists():
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu = line.partition(":")[2].strip()
                break
    return {"cpu": cpu, "cpus": os.cpu_count(), "architecture": platform.machine(), "system": platform.system()}


def load_sample():
    return {"at_ns": time.time_ns(), "load": list(os.getloadavg()), "nice": os.getpriority(os.PRIO_PROCESS, 0)}


def binary_digest(binary):
    with binary.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256") if hasattr(hashlib, "file_digest") else hashlib.sha256(source.read())
    return digest.hexdigest()


def phase_timings(records, exec_ns, frame_ns):
    events = []
    pending = {}
    durations = {}
    for record in sorted(records, key=lambda value: value.get("origin_ns", value["time_ns"])):
        timestamp = record.get("origin_ns", record["time_ns"])
        if not exec_ns <= timestamp <= frame_ns:
            continue
        event = {**record, "exec_ms": (timestamp - exec_ns) / 1e6}
        events.append(event)
        phase = record["phase"] + (":" + record["owner"] if record.get("owner") else "")
        key = (record["pid"], record.get("actor", ""), phase)
        if record.get("stage") == "begin":
            pending[key] = timestamp
        elif record.get("stage") in ("end", "failed") and key in pending:
            durations.setdefault(phase, []).append((timestamp - pending.pop(key)) / 1e6)
    return {"events": events, "durations_ms": durations, "pending": [key[2] for key in pending]}


def read_phases(folder, exec_ns, frame_ns):
    records = []
    for file in sorted((folder / "trace").glob("boot-*.jsonl")):
        for line in file.read_text().splitlines():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise RuntimeError(f"incomplete phase log: {file}") from error
    return phase_timings(records, exec_ns, frame_ns)


def measure(binary, folder, label, environment):
    # Imports stay local so the load/regression unit tests start no native fixtures.
    from native_workspace import NativeDesktop
    import select

    load = [load_sample()]
    started_ns = time.monotonic_ns()
    exec_ns = time.time_ns()
    observed_environment = {**environment, "WIPPY_LUA_CACHE_STATS_FILE": str(folder / "trace" / f"{label}-cache.json")}
    ui = NativeDesktop(binary, folder / "project", folder / "state", home=folder / "home", environment=observed_environment)
    first_frame_ms = None
    frame_ns = None
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if select.select([ui.master], [], [], 0.01)[0]:
                try:
                    chunk = os.read(ui.master, 65536)
                except OSError:
                    break
                observed_ns = time.monotonic_ns()
                ui.raw.extend(chunk)
                ui.pending_output += ui.decoder.decode(chunk)
                begin, end = "\x1b[?2026h", "\x1b[?2026l"
                while ui.pending_output:
                    start = ui.pending_output.find(begin)
                    if start < 0:
                        safe = max(0, len(ui.pending_output) - len(begin) + 1)
                        ui.stream.feed(ui.pending_output[:safe])
                        ui.pending_output = ui.pending_output[safe:]
                        break
                    finish = ui.pending_output.find(end, start + len(begin))
                    if finish < 0:
                        break
                    ui.stream.feed(ui.pending_output[:start] + ui.pending_output[start + len(begin):finish])
                    ui.pending_output = ui.pending_output[finish + len(end):]
                    if first_frame_ms is None and " BEE " in ui.text():
                        first_frame_ms = (observed_ns - started_ns) / 1e6
                        frame_ns = exec_ns + observed_ns - started_ns
            if first_frame_ms is not None:
                break
            if ui.process.poll() is not None:
                break
        if first_frame_ms is None:
            raise RuntimeError(f"{label}: no complete Desktop frame; client exit={ui.process.poll()}")
        # Readiness is a separate observation: an early Starting scene is a frame,
        # and never proof that a workspace or an application has become ready.
        if "Starting…" in ui.text():
            ui.wait_until(lambda: "Starting…" not in ui.text() and " BEE " in ui.text(), "Desktop readiness", timeout=120)
        ready_ms = (time.monotonic_ns() - started_ns) / 1e6
        ui.quit()
        print(f"{label}: first frame {first_frame_ms:.3f} ms; ready {ready_ms:.3f} ms", flush=True)
        return {"scenario": label, "exec_ns": exec_ns, "first_frame_ms": first_frame_ms,
                "ready_ms": ready_ms, "client_pid": ui.process.pid, "load": load,
                "frame_ns": frame_ns, "evidence_dir": str(folder)}
    finally:
        load.append(load_sample())
        (folder / f"{label}-pty.bin").write_bytes(ui.raw)
        ui.close()


def stop(binary, folder, environment):
    result = subprocess.run([str(binary), "--state", str(folder / "state"), "stop"],
                            cwd=folder / "project", env=environment, capture_output=True, timeout=90)
    (folder / "stop.log").write_bytes(result.stdout + result.stderr)
    if result.returncode:
        # A failed launch may never publish a rendezvous. Cleanup uses held
        # process identities, preserves the failed state, and still fails the gate.
        from native_client import live_owners, hold_owner
        for pid in live_owners(binary, folder / "state"):
            handle = hold_owner(pid, binary, folder / "state")
            if handle is not None:
                try:
                    handle.stop()
                finally:
                    handle.close()
        raise RuntimeError(f"owner stop failed ({result.returncode}); see {folder / 'stop.log'}")


def prepare(folder):
    for name in ("project", "home", "work", "trace"):
        (folder / name).mkdir(parents=True)
    return {"PATH": "/usr/bin:/bin", "HOME": str(folder / "home"),
            "XDG_CONFIG_HOME": str(folder / "home/.config"), "TERM": "xterm-256color",
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TMPDIR": str(folder / "work"),
            "BEE_BOOT_LOG_DIR": str(folder / "trace")}


def run(args):
    identity = machine()
    # Never silently measure at a lower priority than the brief specifies.
    try:
        os.setpriority(os.PRIO_PROCESS, 0, 0)
    except PermissionError:
        pass
    initial = load_sample()
    accepted = eligible(initial["load"], identity["cpus"], initial["nice"], args.max_load)
    if not accepted and not args.diagnostic:
        raise RuntimeError(f"machine is not idle enough at nice 0: {initial}; use a quiet window (max normalized load {args.max_load})")
    base = ROOT / ".wippy/boot-measure"
    base.mkdir(parents=True, exist_ok=True)
    current_digest, previous_digest = binary_digest(args.binary), binary_digest(args.previous)
    if current_digest == previous_digest:
        raise RuntimeError("upgrade requires a previous build different from the current executable")
    output = Path(tempfile.mkdtemp(prefix="run-", dir=base))
    results = {"schema": 1, "machine": identity, "binary_sha256": current_digest,
               "previous_sha256": previous_digest, "targets_ms": TARGETS_MS,
               "max_normalized_load": args.max_load, "samples": [], "eligible": accepted}
    try:
        for index in range(args.runs):
            folder = output / str(index)
            environment = prepare(folder)
            try:
                results["samples"].append(measure(args.binary, folder, "fresh", environment))
                results["samples"].append(measure(args.binary, folder, "attach", environment))
                stop(args.binary, folder, environment)
                results["samples"].append(measure(args.binary, folder, "warm", environment))
            finally:
                stop(args.binary, folder, environment)
            upgraded = output / f"{index}-upgrade"
            environment = prepare(upgraded)
            try:
                measure(args.previous, upgraded, "previous", environment)
            finally:
                stop(args.previous, upgraded, environment)
            try:
                results["samples"].append(measure(args.binary, upgraded, "upgrade", environment))
            finally:
                stop(args.binary, upgraded, environment)
        results["eligible"] = accepted and all(eligible(observation["load"], identity["cpus"], observation["nice"], args.max_load)
                                               for sample in results["samples"] for observation in sample["load"])
        # Owners have exited, so their accepted log events have drained and
        # concurrent writes cannot leave a partial record in this snapshot.
        for sample in results["samples"]:
            sample["phases"] = read_phases(Path(sample["evidence_dir"]), sample["exec_ns"], sample["frame_ns"])
        results["cache_stats"] = {str(path.relative_to(output)): json.loads(path.read_text())
                                  for path in sorted(output.glob("*/trace/*-cache.json"))}
        results["medians_ms"] = {name: statistics.median(sample["first_frame_ms"] for sample in results["samples"] if sample["scenario"] == name)
                                 for name in SCENARIOS}
        failures = []
        if any(not sample["phases"]["events"] for sample in results["samples"]):
            failures.append("current executable did not emit phase logs; rebuild the instrumented standalone binary")
        if not results["eligible"]:
            failures.append("overloaded or nonzero-nice sample; diagnostic evidence cannot establish or pass a baseline")
        if args.diagnostic:
            failures.append("diagnostic mode never establishes or passes a regression baseline")
        elif not failures and args.record:
            if args.baseline.exists():
                failures.append("baseline already exists; choose a new filename for an intentional baseline revision")
            else:
                args.baseline.parent.mkdir(parents=True, exist_ok=True)
                args.baseline.write_text(json.dumps(results, indent=2) + "\n")
        elif not failures:
            baseline = json.loads(args.baseline.read_text())
            if not baseline.get("eligible"):
                failures.append("baseline is not load eligible")
            else:
                failures.extend(compare(baseline, results, args.tolerance))
        results["failures"] = failures
        print(json.dumps({"evidence": str(output), "medians_ms": results["medians_ms"], "failures": failures}, indent=2), flush=True)
        return 1 if failures else 0
    finally:
        (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=lambda value: Path(value).resolve())
    parser.add_argument("--previous", required=True, type=lambda value: Path(value).resolve())
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--diagnostic", action="store_true", help="retain overloaded evidence and fail; never update the baseline")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--max-load", type=float, default=0.5)
    parser.add_argument("--tolerance", type=float, default=0.2)
    args = parser.parse_args()
    if args.runs < 1 or not 0 < args.max_load <= 1 or not 0 <= args.tolerance <= 1:
        parser.error("runs must be positive; load must be in (0,1]; tolerance must be in [0,1]")
    raise SystemExit(run(args))


if __name__ == "__main__":
    main()
