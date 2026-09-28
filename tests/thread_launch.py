"""thread_launch acceptance with the scripted fixture provider and no account.

An orchestrator agent is admitted with thread_launch in its own launch policy,
which allow-lists exactly one worker definition. It calls thread_launch over
the real gateway; the owner operation starts the worker's own managed carrier
through the ordinary launch pipeline, the scripted worker reads its thread,
posts its answer and settles, and the orchestrator's thread_wait returns. The
worker's gateway tools are its own launch policy's, and lineage records the
orchestrator's action as the parent of the child's. A second case exercises the
managed-run tools: a managed orchestrator launches a Codex batch worker on a new
thread, registers thread_notify immediately from the returned attempt IDs,
wakes on thread_wait, reads the child's own
thread as member_thread, queries run_status, steers the child once, and cancels a
second worker with run_cancel.

Required environment: BEE_RUNTIME (the combined runtime binary) only.
"""
import os
import re
import json
import sqlite3
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import RUNTIME, fixture_workspace  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ACCEPTANCE = "starts an allow-listed child, delivers the brief, and waits for its answer and settlement"
RUN_ACCEPTANCE = "launches a Codex worker on a new thread, follows its run by notify and wait, steers it, and cancels a second worker"
TESTS = ("bee.harness.catalog:agent_launch_acceptance_test", "bee.harness.catalog:agent_run_acceptance_test")
LIVE_TEST = ("bee.harness.catalog:agent_launch_acceptance_test",)


def live_environment(folder, home, provider, executable):
    return {
        "HOME": str(home),
        "PATH": os.environ.get("PATH", os.defpath),
        "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"),
        "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers"),
        "BEE_AMBIENT_LIVE_PROVIDER": provider,
        f"BEE_{provider.split('-')[0].upper()}_BIN": str(executable),
    }


def run_live_case(home, provider, selector, executable, capture=None):
    with fixture_workspace(managed_gateway=True) as folder:
        environment = live_environment(folder, home, selector, executable)
        if provider == "claude":
            capture_path = capture(folder) if capture else None
        else:
            capture_path = None
        started = time.time()
        try:
            run = subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal", "test", *LIVE_TEST],
                                 cwd=folder, capture_output=True, text=True,
                                 timeout=900 if selector == "claude-long" else 600, env=environment)
        except subprocess.TimeoutExpired:
            sys.exit(f"Live {selector} smoke failed (runtime timeout; output withheld)")
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        raw = raw_stream_summary(capture_path) if capture_path else None
        if raw:
            print("Claude long batch raw stdout: "
                  f"{raw['result_count']} result envelope(s), {raw['docs_calls']} docs calls, "
                  f"{raw['duration_ms']} ms, successful={raw['success']}, answer_marker={raw['marker']}")
        passed = re.search(r"^\s+o .*" + re.escape(ACCEPTANCE), out, re.M)
        if run.returncode != 0 or not passed:
            safe_failure = "completion proof failed"
            for stage in ("host setup", "orchestrator completion", "orchestrator settlement", "child launch report",
                          "child identity", "child completion", "child terminal envelope record"):
                if f"live {provider} smoke failed during {stage}" in out or f"live Claude long batch failed during {stage}" in out:
                    safe_failure = "acceptance stage " + stage
                    break
            sys.exit(f"Live {selector} smoke failed (runtime exit {run.returncode}; "
                     f"{safe_failure}); output withheld")
        if selector == "claude-long" and (not raw or raw["result_count"] != 1 or not raw["success"]
                                          or not raw["marker"] or raw["docs_calls"] < 48
                                          or raw["duration_ms"] < 180_000):
            sys.exit("Live Claude long batch failed (raw CLI stream did not prove the required multi-minute research run)")
        print(f"Live {selector} smoke: Bee recorded the terminal child result in {time.time() - started:.1f} s")


def raw_stream_summary(path):
    if not path or not path.is_file():
        return {"result_count": 0, "success": False, "marker": False, "duration_ms": 0, "docs_calls": 0,
                "bytes": 0, "lines": 0, "types": {}, "system_subtypes": {}, "rate_limit_statuses": {},
                "tool_results": 0, "tool_result_errors": 0, "tool_operations": {},
                "tool_names": {}, "tool_error_codes": {}}
    result_count = 0
    success = False
    marker = False
    duration_ms = 0
    docs_calls = 0
    lines = 0
    bytes_captured = path.stat().st_size
    types = {}
    system_subtypes = {}
    rate_limit_statuses = {}
    tool_results = 0
    tool_result_errors = 0
    tool_operations = {}
    tool_names = {}
    tool_error_codes = {}
    expected = "bee-long-batch-result-envelope-recorded"
    with path.open("rb") as stream:
        for raw in stream:
            lines += 1
            try:
                envelope = json.loads(raw)
            except (UnicodeDecodeError, ValueError):
                continue
            if not isinstance(envelope, dict):
                continue
            kind = envelope.get("type")
            if isinstance(kind, str):
                types[kind] = types.get(kind, 0) + 1
            if kind == "system" and isinstance(envelope.get("subtype"), str):
                subtype = envelope["subtype"]
                system_subtypes[subtype] = system_subtypes.get(subtype, 0) + 1
            if kind == "rate_limit_event":
                detail = envelope.get("rate_limit_info")
                status = detail.get("status") if isinstance(detail, dict) else None
                if isinstance(status, str):
                    rate_limit_statuses[status] = rate_limit_statuses.get(status, 0) + 1
            if kind == "result":
                result_count += 1
                success = envelope.get("subtype") == "success" and envelope.get("is_error") is False
                marker = isinstance(envelope.get("result"), str) and expected in envelope["result"]
                duration_ms = max(duration_ms, int(envelope.get("duration_ms") or 0))
            if envelope.get("type") == "assistant":
                message = envelope.get("message")
                blocks = message.get("content", []) if isinstance(message, dict) else []
                if isinstance(blocks, list):
                    for block in blocks:
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        name = block.get("name")
                        if isinstance(name, str):
                            tool_names[name] = tool_names.get(name, 0) + 1
                        if name != "mcp__bee__docs":
                            continue
                        docs_calls += 1
                        tool_input = block.get("input")
                        operation = tool_input.get("operation") if isinstance(tool_input, dict) else None
                        if isinstance(operation, str):
                            tool_operations[operation] = tool_operations.get(operation, 0) + 1
            if kind == "user":
                message = envelope.get("message")
                blocks = message.get("content", []) if isinstance(message, dict) else []
                if isinstance(blocks, list):
                    for block in blocks:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        tool_results += 1
                        if block.get("is_error") is True:
                            tool_result_errors += 1
                            content = block.get("content")
                            if isinstance(content, str):
                                codes = re.findall(r"\b(?:INVALID_ARGUMENT|NOT_FOUND|UNAVAILABLE|INTERNAL|FORBIDDEN|TIMEOUT|CONFLICT|RESOURCE_EXHAUSTED)\b", content)
                                for code in codes:
                                    tool_error_codes[code] = tool_error_codes.get(code, 0) + 1
    return {"result_count": result_count, "success": success, "marker": marker,
            "duration_ms": duration_ms, "docs_calls": docs_calls, "types": types,
            "bytes": bytes_captured, "lines": lines, "system_subtypes": system_subtypes,
            "rate_limit_statuses": rate_limit_statuses, "tool_results": tool_results,
            "tool_result_errors": tool_result_errors, "tool_operations": tool_operations,
            "tool_names": tool_names, "tool_error_codes": tool_error_codes}


def bee_live_summary(folder):
    summary = {"attempts": [], "receipts": [], "output_states": {}}
    placement_db = folder / ".wippy/placement.db"
    if placement_db.is_file():
        with sqlite3.connect(placement_db) as db:
            attempts = db.execute("SELECT attempt_id, execution_state, cleanup_state, exit_code "
                                  "FROM bee_placement_attempts ORDER BY created_at").fetchall()
            for attempt_id, execution, cleanup, exit_code in attempts:
                evidence = db.execute("SELECT kind, detail FROM bee_placement_evidence WHERE attempt_id=? "
                                      "AND kind IN ('output.lost','output.drain_elapsed','child.exited','runner.finished') "
                                      "ORDER BY sequence", (attempt_id,)).fetchall()
                summary["attempts"].append({"attempt_id": attempt_id, "execution": execution, "cleanup": cleanup,
                                            "exit_code": exit_code, "evidence": evidence})
    threads_db = folder / ".wippy/threads.db"
    if threads_db.is_file():
        with sqlite3.connect(threads_db) as db:
            rows = db.execute("SELECT attempt_id, thread_id, action_id, kind, record_json FROM bee_thread_records "
                              "WHERE kind IN ('observation','receipt') ORDER BY thread_id, sequence").fetchall()
        observations = {}
        receipts = []
        marker = "bee-long-batch-result-envelope-recorded"
        def has_answer_marker(value):
            if isinstance(value, dict):
                if value.get("type") == "text" and marker in str(value.get("text", "")):
                    return True
                return any(has_answer_marker(nested) for nested in value.values())
            if isinstance(value, list):
                return any(has_answer_marker(nested) for nested in value)
            return False
        for attempt_id, thread_id, action_id, kind, raw in rows:
            try:
                record = json.loads(raw)
            except (TypeError, ValueError):
                continue
            if kind == "observation":
                observations.setdefault(attempt_id, False)
                observations[attempt_id] = observations[attempt_id] or has_answer_marker(record)
                body = record.get("body") if isinstance(record, dict) else None
                data = body.get("data") if isinstance(body, dict) else None
                if isinstance(data, dict) and data.get("event_name") == "bee.carrier.output":
                    try:
                        state = json.loads(data.get("payload_json", "{}")).get("state")
                    except (TypeError, ValueError):
                        state = None
                    if isinstance(state, str):
                        summary["output_states"][state] = summary["output_states"].get(state, 0) + 1
            else:
                body = record.get("body") if isinstance(record, dict) else None
                outcome = body.get("outcome") if isinstance(body, dict) else None
                receipts.append({"attempt_id": attempt_id, "thread_id": thread_id, "action_id": action_id,
                                 "outcome": outcome, "answer_marker": observations.get(attempt_id, False)})
        summary["receipts"] = receipts
    return summary


def run_live_smokes(long_only=False):
    home = Path.home()
    logins = {
        "claude": home / ".claude/.credentials.json",
        "codex": home / ".codex/auth.json",
    }
    if not long_only:
        for provider, login_path in logins.items():
            if not login_path.is_file():
                print(f"Live {provider} orchestrator smoke: skipped (login file absent)")
                continue
            command = shutil.which(provider)
            if not command:
                print(f"Live {provider} orchestrator smoke: skipped (CLI absent)")
                continue
            run_live_case(home, provider, provider, Path(command).resolve())
        return

    login_path = logins["claude"]
    command = shutil.which("claude")
    if not login_path.is_file() or not command:
        print("Live Claude long batch: skipped (login file or CLI absent)")
        return
    real_cli = Path(command).resolve()
    tee = shutil.which("tee")
    if not tee:
        sys.exit("Live Claude long batch requires tee")

    def tee_wrapper(folder):
        capture_path = folder / "claude-child.stdout.jsonl"
        status_path = folder / "claude-child.exit-code"
        args_path = folder / "claude-child.launch-summary"
        wrapper = folder / "claude-tee"
        wrapper.write_text("#!/usr/bin/env bash\nset -o pipefail\n"
                           "max_turns=unset\ninput_format=unset\noutput_format=unset\nprevious=''\n"
                           "for argument in \"$@\"; do\n"
                           "  if [ \"$previous\" = '--max-turns' ]; then max_turns=\"$argument\"; fi\n"
                           "  if [ \"$previous\" = '--input-format' ]; then input_format=\"$argument\"; fi\n"
                           "  if [ \"$previous\" = '--output-format' ]; then output_format=\"$argument\"; fi\n"
                           "  previous=\"$argument\"\n"
                           "done\n"
                           f"printf 'max_turns=%s\\ninput_format=%s\\noutput_format=%s\\n' \"$max_turns\" \"$input_format\" \"$output_format\" > {shlex.quote(str(args_path))}\n"
                           f"{shlex.quote(str(real_cli))} \"$@\" | {shlex.quote(str(Path(tee).resolve()))} -a {shlex.quote(str(capture_path))}\n"
                           "status=$?\n"
                           f"printf '%s\\n' \"$status\" > {shlex.quote(str(status_path))}\n"
                           "exit \"$status\"\n")
        wrapper.chmod(0o700)
        return capture_path, status_path, args_path

    with fixture_workspace(managed_gateway=True) as folder:
        capture_path, status_path, args_path = tee_wrapper(folder)
        environment = live_environment(folder, home, "claude-long", folder / "claude-tee")
        started = time.time()
        try:
            run = subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal", "test", *LIVE_TEST],
                                 cwd=folder, capture_output=True, text=True, timeout=900, env=environment)
        except subprocess.TimeoutExpired:
            sys.exit("Live Claude long batch failed (runtime timeout; output withheld)")
        print(f"Claude long batch runtime exit {run.returncode} after {time.time() - started:.1f} s")
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        raw = raw_stream_summary(capture_path)
        print("Claude long batch raw stdout: "
              f"{raw['result_count']} result envelope(s), {raw['docs_calls']} docs calls, "
              f"{raw['duration_ms']} ms, successful={raw['success']}, answer_marker={raw['marker']}, "
              f"bytes={raw['bytes']}, lines={raw['lines']}, types={raw['types']}, "
              f"system_subtypes={raw['system_subtypes']}, rate_limits={raw['rate_limit_statuses']}, "
              f"tool_results={raw['tool_results']}, tool_errors={raw['tool_result_errors']}, "
              f"operations={raw['tool_operations']}, tool_names={raw['tool_names']}, "
              f"tool_error_codes={raw['tool_error_codes']}, "
              f"process_exit={status_path.read_text().strip() if status_path.is_file() else 'missing'}, "
              f"launch={args_path.read_text().replace(chr(10), ',').strip(',') if args_path.is_file() else 'missing'}")
        bee = bee_live_summary(folder)
        bee_marker = any(receipt["answer_marker"] for receipt in bee["receipts"])
        bee_success = any(receipt["outcome"] == "succeeded" for receipt in bee["receipts"])
        print("Bee long batch records: "
              f"answer_marker={bee_marker}, successful_receipt={bee_success}, "
              f"output_states={bee['output_states']}, receipts={bee['receipts']}, attempts={bee['attempts']}")
        passed = re.search(r"^\s+o .*" + re.escape(ACCEPTANCE), out, re.M)
        if run.returncode != 0 or not passed:
            safe_failure = "completion proof failed"
            for stage in ("host setup", "orchestrator completion", "orchestrator settlement", "child launch report",
                          "child identity", "child completion", "child terminal envelope record"):
                if f"live claude smoke failed during {stage}" in out or f"live Claude long batch failed during {stage}" in out:
                    safe_failure = "acceptance stage " + stage
                    break
            for outcome in ("succeeded", "failed", "cancelled", "uncertain"):
                if f"worker receipt outcome {outcome}" in out:
                    safe_failure += f" (child outcome {outcome})"
                    break
            sys.exit(f"Live Claude long batch failed (runtime exit {run.returncode}; {safe_failure}); output withheld")
        if (raw["result_count"] != 1 or not raw["success"] or not raw["marker"]
                or raw["docs_calls"] < 64 or raw["tool_operations"].get("search", 0) < 64
                or raw["duration_ms"] < 180_000):
            sys.exit("Live Claude long batch failed (raw CLI stream did not prove the required multi-minute research run)")
        if not bee_marker or not bee_success:
            sys.exit("Live Claude long batch failed (Bee did not record the raw result marker and successful receipt)")
        print(f"Live Claude long batch: Bee recorded the terminal result in {time.time() - started:.1f} s")


def main():
    if sys.argv[1:] not in ([], ["--live"], ["--live-long"]):
        sys.exit("usage: thread_launch.py [--live|--live-long]")
    run_live = sys.argv[1:] in (["--live"], ["--live-long"])
    long_only = sys.argv[1:] == ["--live-long"]
    if not RUNTIME.is_file():
        sys.exit(f"BEE_RUNTIME must name the combined runtime binary; got {RUNTIME!r}")
    with fixture_workspace(managed_gateway=True) as folder:
        repository = folder / ".wippy/carrier-main"
        subprocess.run(["git", "init", "--quiet", str(repository)], check=True)
        subprocess.run(["git", "-C", str(repository), "config", "user.name", "Bee Fixture"], check=True)
        subprocess.run(["git", "-C", str(repository), "config", "user.email", "bee-fixture@example.test"], check=True)
        (repository / "seed.txt").write_text("initial commit\n")
        subprocess.run(["git", "-C", str(repository), "add", "seed.txt"], check=True)
        subprocess.run(["git", "-C", str(repository), "commit", "--quiet", "-m", "fixture base"], check=True)
        environment = {**os.environ, "BEE_FIXTURE_BIN": str(folder / "fixtures/harness/bin"),
                       "BEE_FIXTURE_STREAMS": str(folder / "fixtures/drivers"), "BEE_FIXTURE_GIT_COMMIT": "1",
                       "BEE_AMBIENT_LIVE_PROVIDER": "none"}
        environment.pop("ANTHROPIC_API_KEY", None)
        started = time.time()
        run = subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal", "test", *TESTS],
                             cwd=folder, capture_output=True, text=True,
                             timeout=int(os.environ.get("BEE_THREAD_LAUNCH_TIMEOUT", "600")), env=environment)
        out = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        print(f"runtime test exit {run.returncode} after {time.time() - started:.1f} s")
        for line in out.splitlines():
            if re.search(r"^\s+x |_test:\d+:|assertion failed", line):
                print(line[:400])
        if run.returncode != 0:
            sys.exit(run.returncode)
        for acceptance in (ACCEPTANCE, RUN_ACCEPTANCE):
            if not re.search(r"^\s+o .*" + re.escape(acceptance), out, re.M):
                sys.exit("the thread_launch acceptance did not pass: " + acceptance)
        subjects = subprocess.run(["git", "-C", str(repository), "log", "--format=%s"], check=True,
                                  capture_output=True, text=True).stdout.splitlines()
        if "bee fixture commit" not in subjects:
            sys.exit("the confined Codex fixture worker did not commit in its Git repository")
        dirty = subprocess.run(["git", "-C", str(repository), "status", "--porcelain"], check=True,
                               capture_output=True, text=True).stdout
        if dirty:
            sys.exit("the confined Codex fixture worker left uncommitted changes")
        print("Thread launch (fixture provider, no account): an orchestrator agent starts an "
              "allow-listed worker over the real gateway, the worker answers and settles, and the "
              "orchestrator's thread_wait returns its answer and terminal outcome; a managed orchestrator "
              "launches a confined Codex fixture worker that commits in a Git repository, follows its run by "
              "notify and wait, steers it, and cancels a second worker")

    if run_live:
        run_live_smokes(long_only=long_only)


if __name__ == "__main__":
    main()
