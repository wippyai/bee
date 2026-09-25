"""Native terminal acceptance and application authority checks in a real PTY."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import yaml
from processes import ProcessHandle
from tui_smoke import DESKTOP_HANG_SECONDS, Desktop, ROOT, RUNTIME
from workspace import pack_deployment

PROBE = '''
    local security = require("security")
    local registry = require("registry")
    local sql = require("sql")
    local database, database_error = sql.get("bee.environment:workspace_db")
    assert(not database and database_error, "App accessed the primary database")
    assert(not security.can("db.get", "bee.environment:workspace_db"))
    local client_database, client_database_error = sql.get("bee.environment:client_db")
    assert(not client_database and client_database_error)
    assert(not security.can("db.get", "bee.environment:client_db"))
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

def exercise(packed, theme="honey"):
    with tempfile.TemporaryDirectory(prefix="bee-console-") as temporary:
        folder = Path(temporary)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        if theme != "honey":
            appearance = project / "modules/application/src/appearance.lua"
            source = appearance.read_text()
            anchor = 'function M.defaults(): Preferences return {theme = "honey",'
            assert source.count(anchor) == 1
            appearance.write_text(source.replace(anchor, f'function M.defaults(): Preferences return {{theme = "{theme}",'))
        for name in ["wippy.lock", ".wippy.yaml", "wippy.yaml"]:
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
        host_index = project / "src/security/_index.yaml"
        host = yaml.safe_load(host_index.read_text())
        host["entries"].append({"name": "probe_broad_policy", "kind": "security.policy", "policy": {
            "actions": ["db.get", "registry.apply", "registry.apply_version", "registry.overlay.apply"],
            "resources": "*", "effect": "allow"}})
        bindings = next(e for e in host["entries"] if e["name"] == "application_admission")["bindings"]
        next(b for b in bindings if b["definition_id"] == "bee.console:app")["policies"].append("bee.security:probe_broad_policy")
        host_index.write_text(yaml.safe_dump(host, sort_keys=False))
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        pack = project / "probe-deployment"
        if packed:
            pack_deployment(project, pack)
        ui = Desktop(folder, packed, project=project, deployment=pack, apps=("bee.console:app", "bee.console:app"))
        shell = None
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
            shell = ProcessHandle(native_pid)
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
            if theme == "classic":
                assert background == "0c0c0c", background
            for y in range(top, bottom-1):
                for x in range(left, right-1):
                    assert ui.screen.buffer[y][x].bg == background
            ui.key(b"\x17")
            ui.wait("Close terminal?")
            ui.key(b"\x1b")
            ui.key(b"printf 'CANCEL_%s\\n' $bee_marker\r")
            ui.wait("CANCEL_keep")
            elapsed = ui.quit(confirm=True)
            assert shell.exited(DESKTOP_HANG_SECONDS), "Native shell leaked after workspace exit"
            print(f"Terminal {'pack' if packed else 'source'} ({theme}): command, wrapped-input resize/erase, interrupt, rejoin, independent PTYs, registry/TTY denial; exit {elapsed:.3f}s")
        finally:
            if shell is not None:
                shell.close()
            ui.close()

def command_handlers(packed):
    with tempfile.TemporaryDirectory(prefix="bee-handlers-") as temporary:
        folder = Path(temporary)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        for name in ("wippy.lock", ".wippy.yaml", "wippy.yaml"):
            shutil.copy2(ROOT / name, project / name)
        index = project / "src/apps/console/_index.yaml"
        document = yaml.safe_load(index.read_text())
        app = next(e for e in document["entries"] if e["name"] == "app")
        # A newly registered name exercises discovery without core/provider edits.
        app["meta"]["application"]["commands"].append({
            "name": "probe", "arguments": ["/bin/cat"], "fullscreen": True})
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        pack = project / "probe-deployment"
        if packed:
            pack_deployment(project, pack)
        ui = Desktop(folder, packed, project=project, deployment=pack, apps=("probe",))
        try:
            ui.wait("/bin/cat")
            ui.key(b"HANDLER_READY\r")
            ui.wait("HANDLER_READY")
            assert any(row.startswith("HANDLER_READY") for row in ui.screen.display), ui.text()
            ui.quit(confirm=True)
        finally:
            ui.close()
        # Admitted duplicate aliases must not silently select one executable.
        other = project / "src/apps/settings/_index.yaml"
        settings = yaml.safe_load(other.read_text())
        next(e for e in settings["entries"] if e["name"] == "app")["meta"]["application"]["commands"] = [{"name": "probe"}]
        other.write_text(yaml.safe_dump(settings, sort_keys=False))
        result = subprocess.run([str(RUNTIME), "run", "bee", "probe"], cwd=project,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and "Ambiguous Bee command: probe" in result.stdout + result.stderr
        del next(e for e in settings["entries"] if e["name"] == "app")["meta"]["application"]["commands"]
        other.write_text(yaml.safe_dump(settings, sort_keys=False))
        host = project / "src/security/_index.yaml"
        composition = yaml.safe_load(host.read_text())
        admission = next(e for e in composition["entries"] if e["name"] == "application_admission")
        admission["bindings"] = [b for b in admission["bindings"] if b["definition_id"] != "bee.console:app"]
        host.write_text(yaml.safe_dump(composition, sort_keys=False))
        result = subprocess.run([str(RUNTIME), "run", "bee", "probe"], cwd=project,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and "Unknown Bee command: probe" in result.stdout + result.stderr
    print(f"Command handlers {'pack' if packed else 'source'}: metadata discovery, fullscreen and duplicate rejection")

if __name__ == "__main__":
    command_handlers(False)
    command_handlers(True)
    exercise(False)
    exercise(True)
    exercise(False, "classic")
    exercise(True, "classic")
