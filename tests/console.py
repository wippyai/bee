"""Native terminal acceptance and application authority checks in a real PTY."""
from pathlib import Path
import os
import re
import time
import shutil
import subprocess
import tempfile
import yaml
from tui_smoke import Desktop, ROOT, RUNTIME

PROBE = '''
    local security = require("security")
    local registry = require("registry")
    local sql = require("sql")
    local database, database_error = sql.get("bee:workspace_db")
    assert(not database and database_error, "App accessed the primary database")
    assert(not security.can("db.get", "bee:workspace_db"))
    assert(security.can("db.get", "foreign-resource"), "Broad test policy was not applied")
    assert(security.can("exec.get", "bee.console:executor"))
    assert(not security.can("exec.get", "other:executor"))
    for _, action in ipairs({"tty.observe", "tty.input", "tty.resize", "tty.mount", "registry.apply", "registry.apply_version", "registry.overlay.apply", "process.security", "process.context", "security.scope.create"}) do
        assert(not security.can(action, "foreign-resource"), "Leaked authority: " .. action)
    end
    local snapshot = assert(registry.snapshot())
    local changes = snapshot:changes()
    changes:create({id = "probe:forbidden", kind = "registry.entry", data = {}})
    local applied, denied = changes:apply()
    assert(not applied and denied and tostring(denied):find("not allowed"), "Direct registry mutation was not denied")
    local own, create_error = tty.viewport({width = 2, height = 2})
    if not own then error(tostring(create_error)) end
    local delegated, delegation_error = own:mount(launch.workspace_pid, {observe = true})
    assert(not delegated and delegation_error, "App minted an ambient TTY mount")
    own:close()
'''

def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-console-") as temporary:
        folder = Path(temporary)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        for name in ["wippy.lock", ".wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        app = project / "src/apps/console/app.lua"
        app.write_text(app.read_text().replace('    local input = assert(tty.events())', PROBE + '\n    local input = assert(tty.events())'))
        index = project / "src/apps/console/_index.yaml"
        doc = yaml.safe_load(index.read_text())
        doc["entries"][0]["modules"] += ["security", "registry", "sql"]
        executor_entry = next(entry for entry in doc["entries"] if entry["name"] == "executor")
        executor_entry["default_env"].update({"HOME": str(folder), "HISTFILE": "/dev/null", "PS1": "$ "})
        index.write_text(yaml.safe_dump(doc, sort_keys=False))
        # Deliberately broad package policy cannot override the host's deny boundary.
        host_index = project / "src/_index.yaml"
        host = yaml.safe_load(host_index.read_text())
        host["entries"].append({"name": "probe_broad_policy", "kind": "security.policy", "policy": {
            "actions": ["db.get", "registry.apply", "registry.apply_version", "registry.overlay.apply"],
            "resources": "*", "effect": "allow"}})
        bindings = next(e for e in host["entries"] if e["name"] == "application_admission")["bindings"]
        next(b for b in bindings if b["definition_id"] == "bee.console:app")["policies"].append("bee:probe_broad_policy")
        host_index.write_text(yaml.safe_dump(host, sort_keys=False))
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        pack = folder / "probe.wapp"
        if packed:
            subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        ui = Desktop(folder, packed, project=project, pack_file=pack, apps=("bee.console:app", "bee.console:app"))
        try:
            ui.wait("Terminal")
            ui.key(b"printf 'SHELL_%s\\n' READY\r")
            ui.wait("SHELL_READY")
            # Readline editing, not merely forwarding bytes to a minimal sh.
            ui.key(b"printf 'ARROW_%s\\n' OX\x1b[D\x1b[3~K\r")
            ui.wait("ARROW_OK")
            ui.key(b"printf 'BACK_%s\\n' OX\x7fK\r")
            ui.wait("BACK_OK")
            ui.key(b"discard\x1b[H\x0bprintf 'HOME_%s\\n' OK\r")
            ui.wait("HOME_OK")
            ui.key(b"printf 'END_%s\\n' O\x1b[H\x1b[FK\r")
            ui.wait("END_OK")
            ui.key(b"printf 'HISTORY_%s\\n' OK\r")
            ui.wait("HISTORY_OK")
            ui.key(b"\x1b[A\x1b[Bprintf 'DOWN_%s\\n' OK\r")
            ui.wait("DOWN_OK")
            # Native process identity and cwd survive presenter replacement.
            ui.key(b"bee_marker=keep; printf 'PID=%s\\n' $$\r")
            ui.wait("PID=")
            native_pid = int(re.search(r"PID=(\d+)", ui.text()).group(1))
            ui.key(b"\x1b[24~")
            ui.key(b"printf 'STATE_%s\\n' $bee_marker\r")
            ui.wait("STATE_keep")
            # Redraw a wrapped, unsubmitted line through four corner resizes,
            # then erase it. Stale cells must not survive the new prompt.
            ui.key(b"printf '\\033[2J\\033[H'\r")
            ui.key(b"BEE_RESIZE_GHOST_" * 6)
            ui.wait("BEE_RESIZE_GHOST_")
            ui.corners()
            ui.key(b"\x15printf 'CLEAN_%s\\n' INPUT\r")
            ui.wait("CLEAN_INPUT")
            assert "BEE_RESIZE_GHOST_" not in ui.text(), ui.text()
            left, top, right, bottom = ui.frame()
            ui.key(b"stty size\r")
            ui.wait(f"{bottom-top-1} {right-left-1}")
            # Multiple terminals have independent shell state and PTYs.
            ui.key(b"\x0e")
            ui.key(b"printf 'ISOLATED_%s\\n' ${bee_marker-unset}\r")
            ui.wait("ISOLATED_unset")
            assert ui.screen.display[0].count("Terminal") == 2, ui.text()
            ui.key(b"exit\r")
            ui.pump(.2)
            ui.key(b"printf 'STATE_%s\\n' $bee_marker\r")
            ui.wait("STATE_keep")
            # Ctrl+C reaches the foreground native process without killing Bee.
            ui.key(b"sleep 30\r")
            ui.key(b"\x03")
            ui.key(b"printf 'INTERRUPT_%s\\n' OK\r")
            ui.wait("INTERRUPT_OK")
            # Blank cells and text share the page background, including edges.
            left, top, right, bottom = ui.frame()
            background = ui.screen.buffer[top][left].bg
            assert background != "default"
            for y in range(top, bottom-1):
                for x in range(left, right-1):
                    assert ui.screen.buffer[y][x].bg == background
            ui.key(b"\x17")
            ui.wait("Close terminal?")
            ui.key(b"\x1b")
            ui.key(b"printf 'CANCEL_%s\\n' $bee_marker\r")
            ui.wait("CANCEL_keep")
            elapsed = ui.quit(confirm=True)
            deadline = time.monotonic() + 1
            while Path(f"/proc/{native_pid}").exists() and time.monotonic() < deadline:
                time.sleep(.02)
            assert not Path(f"/proc/{native_pid}").exists(), "Native shell leaked after workspace exit"
            print(f"Terminal {'pack' if packed else 'source'}: command, wrapped-input resize/erase, interrupt, rejoin, independent PTYs, registry/TTY denial; exit {elapsed:.3f}s")
        finally:
            ui.close()

if __name__ == "__main__":
    exercise(False)
    exercise(True)
