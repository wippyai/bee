"""Actual app-to-shell questions, with source/pack and presenter replacement."""
from pathlib import Path
import shutil
import subprocess
import tempfile
from workspace import ROOT, RUNTIME
from tui_smoke import Desktop


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-interactions-") as directory:
        project = Path(directory) / "project"
        shutil.copytree(ROOT / "src", project / "src")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, project / name)
        source = project / "src/apps/settings/app.lua"
        code = source.read_text().replace('    local announced = false', '''    local answers = assert(process.listen("bee.application.query.result", {message = true}))
    local probes = assert(process.listen("bee.test.query.probe", {message = true}))
    local query_id = ""
    local leaked = 0
    local announced = false''')
        code = code.replace('ticks:case_receive()})', 'ticks:case_receive(), answers:case_receive(), probes:case_receive()})')
        code = code.replace('        elseif event.channel == states then', '''        elseif event.channel == probes and event.value:from() == broker then
            local data: unknown = event.value:payload():data()
            if type(data) == "table" then
                local forged = {version = 1, request_id = data.request_id, id = data.id,
                    instance_id = data.instance_id, action = "accept", value = ""}
                assert(process.send(launch.workspace_pid, "bee.interaction.response", forged))
                assert(process.send(broker, "bee.interaction.response", forged))
            end
        elseif event.channel == answers then
            local answer = client.query_result(launch, tostring(event.value:from()), event.value:payload():data())
            if answer and answer.request_id == query_id then
                status = answer.action .. ":" .. answer.value .. ":leaked=" .. tostring(leaked)
                dirty = true
            end
        elseif event.channel == states then''')
        anchor = '            local data = event.value'
        assert anchor in code
        code = code.replace(anchor, anchor + '''
            if data.type == "key" and data.action ~= "release" then
                if data.key == "!" then
                    query_id = assert(client.query(launch, {kind = "confirm", title = "Confirm fixture", message = "Work will stop.", accept = "Proceed"}))
                elseif data.key == "@" then
                    query_id = assert(client.query(launch, {kind = "text", title = "Name fixture", message = "Enter a name.", accept = "Use name"}))
                elseif data.key == "z" then leaked = leaked + 1 end
            end
''')
        source.write_text(code)
        # Give the fixture app the exact opaque presentation ID so this proves
        # sender authorization, rather than relying on an unguessable ID.
        broker_source = project / "src/core/applications/broker.lua"
        broker_code = broker_source.read_text()
        broker_anchor = '        process.send(owner, "bee.interaction.state", {version = 1, items = items, shutdown = shutdown_dialog and interaction.wire(shutdown_dialog) or nil})'
        assert broker_anchor in broker_code
        broker_code = broker_code.replace(broker_anchor, broker_anchor + '\n        for _, item in pairs(dialogs.items) do process.send(item.execution_pid, "bee.test.query.probe", interaction.wire(item.spec)) end')
        broker_source.write_text(broker_code)

        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        pack = project / "queries.wapp"
        if packed:
            subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        ui = Desktop(directory, packed, project=project, pack_file=pack, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS")
            ui.key(b"!")
            ui.wait("Confirm fixture")
            ui.pump(.4)
            assert "Confirm fixture" in ui.text(), ui.text()
            ui.key(b"zz\r")
            ui.wait("cancel::leaked=0")
            ui.key(b"!")
            ui.wait("Confirm fixture")
            ui.key(b"\x1b[24~")
            ui.pump(.4)
            ui.wait("Confirm fixture")
            ui.key(b"\t\r")
            ui.wait("accept::leaked=0")
            ui.key(b"@")
            ui.wait("Name fixture")
            ui.key("héllo".encode() + b"\r")
            ui.wait("accept:héllo:leaked=0")
            ui.key(b"@")
            ui.wait("Name fixture")
            ui.key(b"\x1b")
            ui.wait("cancel::leaked=0")
            ui.quit()
        finally:
            ui.close()
    print(f'Interactions {"pack" if packed else "source"}: default cancel, explicit accept, Unicode text, Escape, input isolation, forged app response denial, F12 pending replay')


if __name__ == "__main__":
    for packed in (False, True):
        exercise(packed)
