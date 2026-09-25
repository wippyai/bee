"""A rejected core send must exit visibly, retaining acknowledged recovery."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import time

from recovery import stored
from tui_smoke import DESKTOP_HANG_SECONDS, Desktop, ROOT, RUNTIME
from workspace import classic_workspace, pack_deployment

CASES = {
    "bind": ("client", 'topic == "bee.app.request" and type(value) == "table" and value.op == "bind"'),
    "restore": ("host", 'topic == "bee.app.request" and type(value) == "table" and value.op == "open"'),
    "shutdown": ("launch", 'topic == "bee.app.request" and type(value) == "table" and value.op == "shutdown"'),
    "scene": ("client", 'topic == "bee.desktop.command" and type(value) == "table" and value.op == "add"'),
    "receipt": ("host", 'topic == "bee.application.persisted"'),
}


def snapshot_values(snapshot):
    # The restored app may acknowledge the same JSON value with another object
    # key order. Preserve comparison of every envelope and checkpoint field.
    result = json.loads(json.dumps(snapshot))
    for record in result["applications"]:
        if record["resume_state"]:
            record["resume_state"] = json.loads(record["resume_state"])
    return result


def run(packed, cases=CASES):
    for case, (owner, condition) in cases.items():
        with tempfile.TemporaryDirectory(prefix="bee-delivery-") as directory:
            folder = Path(directory)
            # Establish an acknowledged real Settings checkpoint before faulting.
            ui = Desktop(folder, apps=("bee.settings:app",))
            try:
                ui.wait("BEE SETTINGS")
                ui.quit()
            finally:
                ui.close()
            baseline_id = classic_workspace(folder / "workspace.db")
            baseline = stored(folder)
            before = baseline["applications"]
            assert before, "Settings did not establish recovery state"

            project = folder / "project"
            shutil.copytree(ROOT / "src", project / "src")
            shutil.copytree(ROOT / "modules", project / "modules")
            for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
                shutil.copy2(ROOT / name, project / name)
            actor = project / "src" / owner / ("supervisor.lua" if owner == "launch" else "main.lua")
            source = actor.read_text()
            recipient = "broker" if owner == "host" else "recipient"
            anchor = f'local sent, err = process.send({recipient}, topic, value)'
            assert source.count(anchor) == 1
            injection = f'''        local sent, err = true, ""
        if {condition} then
            sent, err = false, "Injected core delivery failure"
        else
            local delivered, failure = process.send({recipient}, topic, value)
            sent, err = delivered == true, tostring(failure)
        end'''
            actor.write_text(source.replace(anchor, injection))
            subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
            pack = project / "failure-deployment"
            if packed:
                pack_deployment(project, pack)
            started = time.monotonic()
            ui = Desktop(folder, packed, project=project, deployment=pack)
            try:
                if case in ("shutdown",):
                    ui.wait("BEE SETTINGS")
                    started = time.monotonic()
                    ui.key(b"\x11")
                elif case == "scene":
                    # Restored client geometry initializes the session directly;
                    # a new live view must still cross its structural add edge.
                    ui.wait("BEE SETTINGS")
                    started = time.monotonic()
                    ui.open_start(); ui.choose("Process Manager")
                while ui.process.poll() is None and time.monotonic() - started < DESKTOP_HANG_SECONDS:
                    ui.pump(.02)
                ui.pump(.1)
                assert ui.process.poll() is not None, f"{case}: core delivery hung"
                assert ui.process.returncode != 0, f"{case}: failed delivery claimed success"
                assert b"Core delivery failed:" in ui.raw, bytes(ui.raw[-2000:])
                assert b"Injected core delivery failure" in ui.raw, bytes(ui.raw[-2000:])
                assert classic_workspace(folder / "workspace.db") == baseline_id, f"{case}: failed delivery changed workspace identity"
                recovered = stored(folder)
                after = recovered["applications"]
                if case in ("bind", "restore", "scene"):
                    assert snapshot_values(recovered) == snapshot_values(baseline), (
                        f"{case}: incomplete bootstrap overwrote saved desktop: {baseline!r} -> {recovered!r}")
                assert [(v["id"], v["instance_id"]) for v in after] == [
                    (v["id"], v["instance_id"]) for v in before
                ], f"{case}: failed delivery lost recovery identity"
            finally:
                ui.close()
            # The faulted launch must not poison the next healthy launch of the
            # same form; a packed workspace keeps its deployment's registry.
            ui = Desktop(folder, packed)
            try:
                ui.wait("BEE SETTINGS")
                assert classic_workspace(folder / "workspace.db") == baseline_id, f"{case}: recovery changed workspace identity"
                ui.quit()
            finally:
                ui.close()
    print(f"Core delivery {'pack' if packed else 'source'}: rejected bind/restore/scene/shutdown/receipt exit visibly, retain recovery, healthy reboot")


def routine(packed, cases=("open", "close", "prepare")):
    for case in cases:
        with tempfile.TemporaryDirectory(prefix="bee-command-failure-") as directory:
            folder = Path(directory)
            project = folder / "project"
            shutil.copytree(ROOT / "src", project / "src")
            shutil.copytree(ROOT / "modules", project / "modules")
            for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
                shutil.copy2(ROOT / name, project / name)
            if case == "prepare":
                actor = project / "src/host/main.lua"
                source = actor.read_text().replace("local function main(", "local reject_command = true\nlocal function main(")
                anchor = '                        local sent, err = process.send(broker, "bee.application.shutdown", {version = 1, op = "prepare"})'
                operation = 'process.send(broker, "bee.application.shutdown", {version = 1, op = "prepare"})'
                condition = "reject_command"
            else:
                actor = project / "src/host/clients.lua"
                source = actor.read_text().replace("function M.request(", "local reject_command = true\nfunction M.request(")
                anchor = '    local sent, send_error = process.send(state.broker, "bee.app.request", request)'
                operation = 'process.send(state.broker, "bee.app.request", request)'
                # The initial CLI open must succeed; reject the later user action.
                condition = 'reject_command and request.op == "' + case + '"'
                if case == "open":
                    condition += ' and request.definition_id == "bee.processes:app"'
            assert source.count(anchor) == 1
            source = source.replace(anchor, f'''        local sent, err = true, ""
        if {condition} then
            reject_command = false
            sent, err = false, "Injected command delivery failure"
        else
            local delivered, failure = {operation}
            sent, err = delivered == true, tostring(failure)
        end''')
            if case != "prepare":
                source = source.replace('reject(state, client, request, "delivery_failed", tostring(send_error))',
                                        'reject(state, client, request, "delivery_failed", tostring(err))')
            actor.write_text(source)
            subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
            pack = project / "routine-deployment"
            if packed:
                pack_deployment(project, pack)
            ui = Desktop(folder, packed, project=project, deployment=pack,
                         apps=("bee.console:app" if case == "prepare" else "bee.settings:app",))
            try:
                ui.wait("Terminal" if case == "prepare" else "BEE SETTINGS")
                if case == "open":
                    ui.open_start(); ui.choose("Process Manager")
                else:
                    ui.key(b"\x11" if case == "prepare" else b"\x17")
                ui.wait("Injected command delivery failure")
                assert ui.process.poll() is None
                if case == "open":
                    assert "BEE SETTINGS" in ui.text()
                    ui.open_start(); ui.choose("Process Manager"); ui.wait("Heap")
                elif case == "close":
                    assert "BEE SETTINGS" in ui.text()
                    ui.key(b"\x17"); ui.wait("No applications open")
                else:
                    ui.key(b"printf 'RETAINED_%s\\n' 'PTY'\r")
                    ui.wait("RETAINED_PTY")
                ui.quit(confirm=case == "prepare")
            finally:
                ui.close()
    print(f"Command delivery {'pack' if packed else 'source'}: failed open/close/quit preserve apps, correlated failure clears pending state, explicit retry works")


def targeting(packed):
    for boundary in ("workspace", "broker"):
        for operation in ("open", "close"):
            with tempfile.TemporaryDirectory(prefix="bee-workspace-target-") as directory:
                folder = Path(directory)
                project = folder / "project"
                shutil.copytree(ROOT / "src", project / "src")
                shutil.copytree(ROOT / "modules", project / "modules")
                for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
                    shutil.copy2(ROOT / name, project / name)
                if boundary == "workspace":
                    actor = project / "src/client/main.lua"
                    source = actor.read_text().replace("        local function send(", "        local reject_target = true\n        local function send(")
                    anchor = '            local sent, err = process.send(recipient, topic, value)'
                    owner_id = "workspace_id"
                    prefix = ""
                    delivery = anchor
                else:
                    actor = project / "src/host/clients.lua"
                    source = actor.read_text().replace("function M.request(", "local reject_target = true\nfunction M.request(")
                    anchor = '    local sent, send_error = process.send(state.broker, "bee.app.request", request)'
                    owner_id = "state.workspace_id"
                    prefix = "    local value: unknown = request\n"
                    delivery = anchor.replace(', request)', ', value)')
                assert source.count(anchor) == 1
                # Corrupt one authenticated request. Exercise a missing target
                # for open and a foreign target for close; the next retry is valid.
                target = 'nil' if operation == "open" else f'({owner_id} == string.rep("f", 32) and string.rep("0", 32) or string.rep("f", 32))'
                condition = f'type(value) == "table" and value.op == "{operation}"'
                if operation == "open":
                    condition += ' and value.definition_id == "bee.processes:app"'
                injection = f'''        if reject_target and {condition} then
            reject_target = false
            value.workspace_id = {target}
        end
'''
                actor.write_text(source.replace(anchor, prefix + injection + delivery))
                subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
                pack = project / "target-deployment"
                if packed:
                    pack_deployment(project, pack)
                ui = Desktop(folder, packed, project=project, deployment=pack, apps=("bee.settings:app",))
                try:
                    ui.wait("BEE SETTINGS")
                    if operation == "open":
                        ui.open_start(); ui.choose("Process Manager")
                    else:
                        ui.key(b"\x17")
                    ui.wait("Request targets another workspace")
                    assert ui.process.poll() is None
                    assert "BEE SETTINGS" in ui.text()
                    assert "Heap" not in ui.text()
                    if operation == "open":
                        ui.open_start(); ui.choose("Process Manager"); ui.wait("Heap")
                    else:
                        ui.key(b"\x17"); ui.wait("No applications open")
                    ui.quit()
                finally:
                    ui.close()
    print(f"Workspace targeting {'pack' if packed else 'source'}: both receivers reject missing/foreign targets, preserve apps and accept explicit retry")


if __name__ == "__main__":
    run(False)
    run(True)
    routine(False)
    routine(True)
    targeting(False)
    targeting(True)
