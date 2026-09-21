"""Isolated thread proof: real model assertions, replay, dedupe and authorization."""
import importlib.util
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("thread_demo", ROOT / "tests/fixtures/thread_journal/run.py")
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)

with tempfile.TemporaryDirectory(prefix="bee-thread-test-") as temporary:
    folder = Path(temporary)
    project = demo.stage(folder / "project")
    database = folder / "threads.db"
    environment = {**os.environ, "BEE_THREAD_DEMO_DB": str(database)}
    subprocess.run([str(demo.RUNTIME), "lint"], cwd=project, check=True)
    def run(thread, key, cursor="0", success=True):
        result = subprocess.run([str(demo.RUNTIME), "run", "thread-demo", "--", thread, key, cursor],
                                cwd=project, env=environment, capture_output=True, text=True, timeout=25)
        output = result.stdout + result.stderr
        assert (result.returncode == 0) == success, output
        if success:
            assert "Thread caught up; journal retained." in output, output
        return output
    first = run("project-a", "run-a")
    assert "test.case.passed" in first and "test.run.finished" in first, first
    repeat = run("project-a", "run-a")
    assert "test.run.finished" in repeat, repeat
    resumed = run("project-a", "run-b", "4")
    assert "5  test.run.started" in resumed and "8  test.run.finished" in resumed, resumed
    assert "1  test.run.started" not in resumed
    other = run("project-b", "run-a")
    assert "1  test.run.started" in other, other
    for cursor in ("-1", "0.5", "10001", "not-a-number"):
        invalid = run("project-a", "invalid-cursor", cursor, success=False)
        assert "Invalid cursor" in invalid, invalid
    # Seed committed history in this disposable fixture to exercise several
    # read pages, independently of how quickly the live producer completes.
    with sqlite3.connect(database) as db:
        db.executemany(
            "INSERT INTO thread_demo_events VALUES (?, ?, ?, ?, ?, ?, ?)",
            [("paged", seq, "fixture", str(seq), "test.fixture", "{}", "fixture")
             for seq in range(1, 131)])
    paged = run("paged", "live-run")
    sequences = [int(value) for value in re.findall(r"(?m)^(\d+)  test\.", paged)]
    assert sequences == list(range(1, 135)), paged
    tail = run("paged", "live-run", "129")
    assert [int(value) for value in re.findall(r"(?m)^(\d+)  test\.", tail)] == list(range(130, 135)), tail
    with sqlite3.connect(database) as db:
        assert db.execute("SELECT thread_id,COUNT(*) FROM thread_demo_events GROUP BY thread_id ORDER BY thread_id").fetchall() == [("paged",134),("project-a",8),("project-b",4)]
        assert db.execute("SELECT COUNT(*) FROM thread_demo_schema_migrations").fetchone()[0] == 1
        assert db.execute("SELECT COUNT(*) FROM thread_demo_events WHERE idempotency_key='spoof'").fetchone()[0] == 0
        db.execute("UPDATE thread_demo_schema_migrations SET checksum='changed'")
    bad = run("project-a", "run-c", success=False)
    assert "checksum" in bad, bad
print("Threads: native contract reader, actor/scope framing, bounded read capability, real test events, sender/DB denial, conflicting retry, restart replay, multi-page catch-up, cursor validation/resume, per-thread isolation, migration integrity")
