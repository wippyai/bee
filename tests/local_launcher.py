"""Physical terminal entry owns a TTY-free supervisor and workspace host."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import time

import yaml

from tui_smoke import Desktop
from workspace import ROOT, RUNTIME
from recovery import stored


def run():
    with tempfile.TemporaryDirectory(prefix="bee-local-launcher-") as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        presenter = project / "src/core/terminal/main.lua"
        code = presenter.read_text()
        anchor = 'local action = bindings.action('
        assert code.count(anchor) == 1
        presenter.write_text(code.replace(anchor, 'if event.key_type == "f10" then error("Injected presenter failure") end\n                ' + anchor))
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, project / name)
        index = project / "src/_index.yaml"
        document = yaml.safe_load(index.read_text())
        document["entries"] += [
            {"name": "local_probe_db", "kind": "security.policy", "policy": {
                "actions": ["db.get"], "resources": ["bee.client.db:local"], "effect": "allow"}},
            {"name": "local_probe_spawn", "kind": "security.policy", "policy": {
                "actions": ["process.spawn", "process.spawn.monitored"],
                "resources": ["bee.launch:supervisor"], "effect": "allow"}},
        ]
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        database = project / "src/local_database"
        database.mkdir()
        (database / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "bee.client.db", "entries": [
            {"name": "local", "kind": "db.sql.sqlite", "file": "${env:bee:workspace_db_path}.client"},
        ]}, sort_keys=False))
        index = project / "src/core/client/_index.yaml"
        document = yaml.safe_load(index.read_text())
        entry = next(e for e in document["entries"] if e["name"] == "local")
        entry["meta"] = {"command": {"name": "local-client-probe", "short": "Local entry acceptance", "security": {
            "actor": {"id": "bee.local"}, "policies": ["bee:desktop_policy", "bee:client_spawn_policy",
                "bee:local_probe_db", "bee:local_probe_spawn"]}}}
        command_entry = next(e for e in document["entries"] if e["name"] == "local_command")
        command_entry["meta"] = {"command": {"name": "local-command-probe", "short": "Local handler acceptance",
            "security": entry["meta"]["command"]["security"]}}
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        index = project / "src/apps/console/_index.yaml"
        document = yaml.safe_load(index.read_text())
        next(e for e in document["entries"] if e["name"] == "app")["meta"]["application"]["commands"].append({
            "name": "local-proof", "fullscreen": True,
            "arguments": ["/bin/bash", "-c", 'printf "ARG=<%s>\\n" "$1"; exec /bin/cat', "bee-probe"]})
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=project, check=True)
        pack = root / "local.wapp"
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            command_folder = root / ("command-pack" if packed else "command-source")
            command_folder.mkdir()
            ui = Desktop(command_folder, packed, project=project, pack_file=pack,
                         command_name="local-command-probe", apps=("bee.client.db:local", "local-proof", "space ; $HOME"))
            try:
                ui.wait("ARG=<space ; $HOME>", timeout=12)
                assert any(row.startswith("ARG=<space ; $HOME>") for row in ui.screen.display), ui.text()
                ui.key(b"\x1b[24~")
                ui.pump(.3)
                ui.key(b"HANDLER_REJOIN_OK\r")
                ui.wait("HANDLER_REJOIN_OK")
                ui.quit(confirm=True)
                print(f"Local command {'pack' if packed else 'source'}: admitted handler, literal arguments, fullscreen and F12", flush=True)
            finally:
                ui.close()
            folder = root / ("pack" if packed else "source")
            folder.mkdir()
            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local", "bee.console:app"))
            try:
                ui.wait("Terminal", timeout=12)
                ui.key(b"bee_local=alive; printf 'LOCAL_%s_OK\\n' \"$bee_local\"\r")
                ui.wait("LOCAL_alive_OK")
                ui.key(b"\x1b[24~")
                ui.pump(.3)
                ui.key(b"printf 'REJOIN_%s_OK\\n' \"$bee_local\"\r")
                ui.wait("REJOIN_alive_OK")
                ui.key(b"\x1b[21~")
                ui.wait("Desktop paused")
                ui.key(b"\x1b[24~")
                ui.pump(.3)
                ui.key(b"printf 'RECOVERED_%s_OK\\n' \"$bee_local\"\r")
                ui.wait("RECOVERED_alive_OK")
                ui.key(b"\x11")
                ui.wait("Quit Bee?")
                ui.key(b"\x1b")
                ui.key(b"printf 'CANCEL_%s_OK\\n' \"$bee_local\"\r")
                ui.wait("CANCEL_alive_OK")
                elapsed = ui.quit(confirm=True)
                print(f"Local entry {'pack' if packed else 'source'}: physical TTY, supervised boot/F12, crash recovery, quit cancellation and cleanup; exit {elapsed:.3f}s", flush=True)
            finally:
                ui.close()

            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local", "bee.console:app"))
            try:
                ui.wait("Terminal", timeout=12)
                ui.key(b"\x1b[21~")
                ui.wait("Emergency exit")
                elapsed = ui.quit()
                print(f"Paused {'pack' if packed else 'source'}: supervised emergency cleanup; exit {elapsed:.3f}s", flush=True)
            finally:
                ui.close()

            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local",))
            try:
                ui.wait("Workspace ", timeout=12)
                ui.pump(.5)
                assert "Terminal" not in ui.text(), "Cold boot retained a dead terminal tab: " + ui.text()
                ui.quit()
                print(f"Cold boot {'pack' if packed else 'source'}: authoritative host inventory removes dead terminal tabs", flush=True)
            finally:
                ui.close()

            restored_folder = root / ("restore-pack" if packed else "restore-source")
            restored_folder.mkdir()
            for initial in (True, False):
                apps = ("bee.client.db:local", "bee.settings:app") if initial else ("bee.client.db:local",)
                ui = Desktop(restored_folder, packed, project=project, pack_file=pack,
                             command_name="local-client-probe", apps=apps)
                try:
                    ui.wait("Honey", timeout=12)
                    ui.quit()
                finally:
                    ui.close()
            print(f"Cold boot {'pack' if packed else 'source'}: recovered Settings retains its client tab and live view", flush=True)

        # Manual recovery belongs to the host, even when the client has discarded
        # its old tab. Opening from Start must receive the saved state and IDs.
        client_file = project / "src/core/client/main.lua"
        client_code = client_file.read_text()
        send_anchor = '        local function send(recipient: string, topic: string, value: unknown)\n'
        reply_anchor = '                            reply = result.reply\n'
        assert client_code.count(send_anchor) == client_code.count(reply_anchor) == 1
        replay_code = client_code.replace(send_anchor,
            '        local replay_request: unknown = nil\n        local replay_id = ""\n        local conflict_seen = false\n' + send_anchor
            + '            if topic == "bee.app.request" and type(value) == "table" and value.op == "open" then\n'
            + '                replay_request = value; replay_id = tostring(value.request_id); conflict_seen = false\n'
            + '                assert(process.send(recipient, topic, value))\n'
            + '                assert(process.send(recipient, topic, {version = 1, op = "open", request_id = value.request_id,\n'
            + '                    workspace_id = value.workspace_id, connection_id = value.connection_id,\n'
            + '                    definition_id = value.definition_id, arguments = {"conflicting"}}))\n'
            + '                return\n            end\n')
        replay_code = replay_code.replace(reply_anchor, reply_anchor + '''                            if reply.request_id == replay_id then
                                if reply.error_code == "request_conflict" then
                                    conflict_seen = true
                                elseif replay_request ~= nil then
                                    assert(reply.error_code == "", "Initial recovery request failed")
                                    local retry = replay_request; replay_request = nil
                                    assert(process.send(host, "bee.app.request", retry))
                                else
                                    assert(reply.error_code == "" and reply.op == "focus", "Completed recovery retry changed its fingerprint")
                                    assert(conflict_seen, "Changed retry was not rejected")
                                    local selected_tab = tab(reply.id, reply.instance_id)
                                    if not selected_tab then error("Retried recovery lost its tab") end
                                    send(session, "bee.desktop.command", {version = 1, op = "announce", id = selected_tab,
                                        instance_id = reply.instance_id, title = "Replay verified"})
                                end
                            end
''')
        client_file.write_text(replay_code)
        settings_index = project / "src/apps/settings/_index.yaml"
        original_settings = settings_index.read_text()
        settings = yaml.safe_load(original_settings)
        next(e for e in settings["entries"] if e["name"] == "app")["meta"]["application"]["restart_policy"] = "manual"
        settings_index.write_text(yaml.safe_dump(settings, sort_keys=False))
        subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=project, check=True)
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("manual-pack" if packed else "manual-source")
            folder.mkdir()
            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local", "bee.settings:app"))
            try:
                ui.wait("Replay verified", timeout=12)
                ui.wait("Honey", timeout=12)
                ui.key(b"\t")
                ui.wait("Solid")
                ui.quit()
            finally:
                ui.close()
            before = stored(folder)["applications"][0]
            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local",))
            try:
                ui.wait("Workspace ", timeout=12)
                ui.pump(.3)
                assert "Settings" not in ui.text(), ui.text()
                ui.open_start(); ui.choose("Settings")
                ui.wait("Replay verified")
                ui.wait("Solid")
                ui.quit()
            finally:
                ui.close()
            after = stored(folder)["applications"][0]
            assert len(stored(folder)["applications"]) == 1, "Recovery replay created another instance"
            assert (after["id"], after["instance_id"]) == (before["id"], before["instance_id"]), (before, after)
            assert json.loads(after["resume_state"]) == json.loads(before["resume_state"]), (before, after)
            print(f"Manual recovery {'pack' if packed else 'source'}: Start restores checkpoint/identity, conflicting retry rejected, completed replay focuses same instance", flush=True)
        settings_index.write_text(original_settings)
        client_file.write_text(client_code)

        # A presenter can stay alive without announcing readiness. The stable
        # terminal owner must provide an exit path without that actor's help.
        code = presenter.read_text()
        ready_anchor = '    assert(process.send(owner, "bee.workspace.control", {version = 1, op = "ready"}))'
        assert code.count(ready_anchor) == 1
        presenter.write_text(code.replace(ready_anchor, '    time.sleep("1h")\n' + ready_anchor))
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("stalled-pack" if packed else "stalled-source")
            folder.mkdir()
            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local", "bee.console:app"))
            try:
                ui.wait("Emergency exit", timeout=8)
                elapsed = ui.quit()
                print(f"Unready presenter {'pack' if packed else 'source'}: bounded pause and emergency exit {elapsed:.3f}s", flush=True)
            finally:
                ui.close()


        # Lose the acknowledgement, not the host operation. Explicit retry must
        # reconcile a completed renderer transition without restarting the PTY.
        presenter.write_text(code)
        clients = project / "src/core/host/clients.lua"
        host_code = clients.read_text()
        anchor = 'local function result(state: State, id: string, op: string, recipient: string, connection_id: string, code: string, message: string)\n'
        assert host_code.count(anchor) == 1
        clients.write_text(host_code.replace(anchor, 'local dropped_render = false\n' + anchor
            + '    if op == "render" and id ~= "" and not dropped_render then dropped_render = true; return end\n'))
        supervisor = project / "src/core/launch/supervisor.lua"
        supervisor_code = supervisor.read_text()
        anchor = 'if next_phase ~= "running" then deadline = time.after("10s") end'
        assert supervisor_code.count(anchor) == 1
        supervisor.write_text(supervisor_code.replace(anchor, anchor
            + '\n            if next_phase == "rendering" then deadline = time.after("2s") end'))
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("lost-reply-pack" if packed else "lost-reply-source")
            folder.mkdir()
            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local", "bee.console:app"))
            try:
                ui.wait("Terminal", timeout=12)
                ui.key(b"bee_retained=alive\r")
                ui.wait("Emergency exit", timeout=8)
                ui.key(b"\x1b[24~")
                ui.pump(.3)
                ui.key(b"printf 'RECONCILED_%s_OK\\n' \"$bee_retained\"\r")
                ui.wait("RECONCILED_alive_OK")
                elapsed = ui.quit(confirm=True)
                print(f"Lost renderer reply {'pack' if packed else 'source'}: bounded pause, explicit reconciliation, retained PTY; exit {elapsed:.3f}s", flush=True)
            finally:
                ui.close()


        # The physical owner must paint before a child becomes ready and observe
        # a failed monitored supervisor without waiting for the boot deadline.
        anchor = '    local function run()\n'
        assert supervisor_code.count(anchor) == 1
        supervisor.write_text(supervisor_code.replace(anchor,
            anchor + '        time.sleep("300ms")\n        error("Injected startup failure")\n'))
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("failed-boot-pack" if packed else "failed-boot-source")
            folder.mkdir()
            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local",))
            try:
                ui.wait("Starting…", timeout=8)
                started = time.monotonic()
                while ui.process.poll() is None and time.monotonic() - started < 3:
                    ui.pump(.05)
                assert ui.process.poll() is not None, "Failed supervisor left boot waiting"
                ui.pump(.1)
                assert b"Local supervisor exited before host readiness" in ui.raw, bytes(ui.raw)
                assert b"\x1b[?1049l" in ui.raw, "Failed boot did not restore the physical terminal"
                print(f"Failed boot {'pack' if packed else 'source'}: immediate boot frame, observed child failure, physical cleanup", flush=True)
            finally:
                ui.close()

        supervisor.write_text(supervisor_code.replace(anchor, anchor + '        time.sleep("1h")\n'))
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("stalled-boot-pack" if packed else "stalled-boot-source")
            folder.mkdir()
            ui = Desktop(folder, packed, project=project, pack_file=pack,
                         command_name="local-client-probe", apps=("bee.client.db:local",))
            try:
                ui.wait("Starting…", timeout=8)
                elapsed = ui.quit()
                assert elapsed < 1, f"Startup exit took {elapsed:.3f}s"
                print(f"Stalled boot {'pack' if packed else 'source'}: Ctrl+Q exits in {elapsed:.3f}s", flush=True)
            finally:
                ui.close()


if __name__ == "__main__":
    run()
