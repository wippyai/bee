"""A live run survives its view; reopening replays its committed results."""
from pathlib import Path
import sqlite3
import shutil
import yaml
import tempfile
import time

from tui_smoke import Desktop
from workspace import ROOT

def exercise(packed):
    with tempfile.TemporaryDirectory(prefix='bee-test-status-') as directory:
        database = Path(directory) / 'threads.db'
        ui = Desktop(directory, packed, apps=('bee.test_status:app', 'desktop-checks', 'acceptance-run'), command_name='bee-app')
        try:
            ui.wait('SHARED UI CHECKS')
            ui.wait('test.run.started')
            ui.key(b'\x17')
            ui.wait('No applications open')
            deadline = time.monotonic() + 8
            complete = False
            while time.monotonic() < deadline:
                with sqlite3.connect(database) as db:
                    complete = db.execute("SELECT COUNT(*) FROM bee_thread_events WHERE event_type='test.run.finished'").fetchone()[0] == 1
                if complete:
                    break
                time.sleep(.05)
            assert complete, 'Closing the view prevented the background run from finishing'
            ui.open_start()
            ui.choose('Tools')
            ui.choose('Test Status')
            ui.wait('COMPLETE')
            ui.wait('6 passed / 0 failed')
            ui.key(b'\x1b[24~')
            ui.wait('COMPLETE')
            ui.quit()
            ui.close()
            # An explicit retry after a cold restart must replay, never duplicate work.
            ui = Desktop(directory, packed, apps=('bee.test_status:app', 'desktop-checks', 'acceptance-run'), command_name='bee-app')
            ui.wait('6 passed / 0 failed')
            ui.pump(.5)
            with sqlite3.connect(database) as db:
                assert db.execute('SELECT COUNT(*) FROM bee_thread_events').fetchone()[0] == 9
                assert db.execute('SELECT COUNT(*) FROM bee_thread_runs').fetchone()[0] == 1
            ui.quit()
        finally:
            ui.close()

def worker_scope():
    with tempfile.TemporaryDirectory(prefix="bee-worker-scope-") as directory:
        project = Path(directory) / "project"
        shutil.copytree(ROOT / "src", project / "src")
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, project / name)
        worker = project / "src/apps/test_status/worker.lua"
        source = worker.read_text()
        anchor = "local function main(thread: string, run: string)"
        assert anchor in source
        source = source.replace(anchor, anchor + """
    local surface, surface_error = tty.surface()
    assert(surface == nil and surface_error ~= nil, "Worker inherited TTY authority")
    local sql = require("sql")
    local database, database_error = sql.get("bee.threads:db")
    assert(database == nil and database_error ~= nil, "Worker inherited direct SQL authority")
""")
        worker.write_text(source)
        index = project / "src/apps/test_status/_index.yaml"
        entries = yaml.safe_load(index.read_text())
        for entry in entries["entries"]:
            if entry["name"] == "worker":
                entry["modules"].append("sql")
        index.write_text(yaml.safe_dump(entries))
        ui = Desktop(directory, project=project, command_name="bee-app",
                     apps=("bee.test_status:app", "scope-test", "scope-run"))
        try:
            ui.wait("6 passed / 0 failed")
            ui.quit()
        finally:
            ui.close()
    print("Background worker: no inherited TTY or direct journal SQL authority")


if __name__ == '__main__':
    worker_scope()
    for packed in (False, True):
        exercise(packed)
        print(f'Test Status {"pack" if packed else "source"}: explicit launch, real checks, independent background completion, reopen/restart replay, idempotent run retry, presenter replacement')
