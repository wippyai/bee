"""Cold-start app recovery with stable identities and newly granted execution."""
from pathlib import Path
import json
import re
import shutil
import sqlite3
import subprocess
import tempfile
import yaml
from tui_smoke import Desktop, ROOT, RUNTIME
from workspace import classic_workspace, client_layout, pack_deployment, workspace_checkpoint

SOURCE = '''local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local json = require("json")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local input = assert(tty.events())
    local lifecycle = assert(process.events())
    local receipts = assert(process.listen("bee.application.checkpoint_result", {message = true}))
    local count = 0
    if launch.resume_state ~= "" then
        local state: unknown = json.decode(launch.resume_state)
        if type(state) ~= "table" or type(state.count) ~= "number" then error("Invalid counter checkpoint") end
        count = math.floor(state.count)
    end
    assert(tty.start())
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local saved = -1
    local closing = false
    local function paint()
        local canvas = tty.canvas(width, height)
        canvas:clear(" ")
        canvas:put(1, 1, "Counter: " .. tostring(count), width)
        canvas:put(1, 2, "Saved: " .. tostring(saved), width)
        canvas:put(1, 3, "Execution: " .. launch.launch_token, width)
        canvas:put(1, 4, "Workspace: " .. client.reference(launch).workspace_id, width)
        assert(output:present(canvas:rows()))
    end
    local function checkpoint()
        local encoded = json.encode({count = count, cleaned = closing})
        assert(client.checkpoint(launch, encoded))
    end
    paint(); client.ready(launch); checkpoint()
    while true do
        local event = channel.select({input:case_receive(), lifecycle:case_receive(), receipts:case_receive()})
        if not event.ok then break end
        if event.channel == lifecycle then
            if event.value.kind == process.event.CANCEL then break end
        elseif event.channel == receipts then
            local msg = event.value
            local data: unknown = msg:payload():data()
            if msg:from() == launch.broker_pid and type(data) == "table" and data.error_code == "" then
                if closing then break end
                saved = count; paint()
            end
        elseif event.value.type == "close" then closing = true; checkpoint()
        elseif event.value.type == "resize" then width, height = event.value.width, event.value.height; paint()
        elseif event.value.type == "key" and event.value.action ~= "release" then count = count + 1; paint(); checkpoint() end
    end
    output:close(); tty.stop()
end
return {main = main}
'''

def stored(folder):
    return workspace_checkpoint(folder / "workspace.db")

def client_stored(folder):
    return client_layout(folder / "workspace.db.client", classic_workspace(folder / "workspace.db"))[1]

def assert_client_identity(folder, record, workspace_id):
    _, layout = client_layout(folder / "workspace.db.client", workspace_id)
    target = next(t for t in layout["targets"] if t["view_id"] == record["id"])
    assert target["workspace_id"] == workspace_id and target["instance_id"] == record["instance_id"]
    window = next(w for w in layout["scene"]["windows"] if w["id"] == target["tab_id"])
    assert window["workspace_id"] == workspace_id and window["instance_id"] == record["instance_id"]

def run(packed):
    with tempfile.TemporaryDirectory(prefix="bee-recovery-") as temporary:
        folder = Path(temporary)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        fixture = project / "src/probe"
        fixture.mkdir()
        (fixture / "app.lua").write_text(SOURCE)
        entry = {"name": "app", "kind": "process.lua", "source": "file://app.lua", "method": "main",
                 "modules": ["tty", "process", "channel", "json"], "imports": {"client": "bee.application:client"},
                 "meta": {"type": "bee.application", "application": {"api_version": 1, "lifetime": "view", "revision": "1",
                 "title": "Counter", "instance_policy": "multiple", "resume_schema": "counter.v1", "restart_policy": "automatic"}}}
        (fixture / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "probe", "entries": [entry]}, sort_keys=False))
        index = project / "src/security/_index.yaml"
        doc = yaml.safe_load(index.read_text())
        admission = next(e for e in doc["entries"] if e["name"] == "application_admission")
        admission["bindings"].append({"definition_id": "probe:app", "policies": []})
        index.write_text(yaml.safe_dump(doc, sort_keys=False))
        # Same authenticated broker, wrong workspace: the owner must not remove
        # its real view when a foreign reply arrives immediately after open.
        broker = project / "src/apps/broker.lua"
        code = broker.read_text()
        send = '        assert(process.send(owner, "bee.app.reply", reply))'
        assert code.count(send) == 1
        code = code.replace(send, send + '''
        if reply.op == "open" and reply.error_code == "" then
            local foreign = contract.reply("", "closed")
            foreign.id, foreign.instance_id = reply.id, reply.instance_id
            foreign.workspace_id = workspace_id == "ffffffffffffffffffffffffffffffff"
                and "00000000000000000000000000000000" or "ffffffffffffffffffffffffffffffff"
            assert(process.send(owner, "bee.app.reply", foreign))
        end''')
        broker.write_text(code)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
        pack = project / "recovery-deployment"
        if packed:
            pack_deployment(project, pack)
        def boot(apps=()):
            ui = Desktop(folder, packed, project=project, deployment=pack, apps=apps)
            try:
                ui.wait("BEE ▾", timeout=12)
            except Exception:
                ui.close()
                raise
            return ui
        ui = boot(("probe:app",))
        try:
            ui.wait("Saved: 0")
            workspace_id = classic_workspace(folder / "workspace.db")
            ui.wait("Workspace: " + workspace_id)
            ui.key(b"ab")
            ui.wait("Saved: 2")
            ui.corners()
            bounds = ui.frame()
            state = stored(folder)
            identity = state["applications"][0]["instance_id"]
            assert_client_identity(folder, state["applications"][0], workspace_id)
            assert "window" not in state["applications"][0], "Host adopted client geometry"
            old_execution = re.search(r"Execution: (\S+)", ui.text()).group(1)
            ui.key(b"\x1b[20;3~")
            ui.quit()
            assert json.loads(stored(folder)["applications"][0]["resume_state"])["cleaned"], "Cooperative close checkpoint was lost"
        finally:
            ui.close()
        # Legacy combined layouts (including absent window workspace IDs) are
        # exercised by local_launcher.public_migration. This path checks that
        # current recovery restores the host's application and client's layout.
        ui = boot()
        try:
            ui.wait("− Counter")
            ui.key(b"\x1b\t")
            ui.wait("Saved: 2")
            ui.wait("Workspace: " + workspace_id)
            assert ui.frame() == bounds, (ui.frame(), bounds)
            assert stored(folder)["applications"][0]["instance_id"] == identity
            assert_client_identity(folder, stored(folder)["applications"][0], workspace_id)
            assert re.search(r"Execution: (\S+)", ui.text()).group(1) != old_execution
            assert old_execution not in json.dumps(stored(folder)), "Execution capability was persisted"
            assert old_execution not in json.dumps(client_stored(folder)), "Client persisted an execution capability"
            ui.key(b"c")
            ui.wait("Saved: 3")
            # Unclean termination must recover the last acknowledged checkpoint.
            ui.process.kill(); ui.process.wait()
        finally:
            ui.close()
        ui = boot()
        try:
            ui.wait("Saved: 3")
            ui.wait("Workspace: " + workspace_id)
            ui.key(b"\x17")
            ui.wait("No applications open")
            ui.quit()
        finally:
            ui.close()
        ui = boot()
        try:
            ui.wait("No applications open")
            assert not stored(folder)["applications"], "Closed app was resurrected"
            ui.quit()
        finally:
            ui.close()
        # A manual contract retains its checkpoint but requires an explicit open.
        entry["meta"]["application"]["restart_policy"] = "manual"
        (fixture / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "probe", "entries": [entry]}, sort_keys=False))
        if packed:
            pack_deployment(project, pack)
        ui = boot(("probe:app",))
        try:
            ui.wait("Saved: 0"); ui.key(b"m"); ui.wait("Saved: 1"); ui.quit()
        finally:
            ui.close()
        ui = boot()
        try:
            ui.wait("No applications open")
            assert stored(folder)["applications"]
            ui.open_start(); ui.choose("Counter"); ui.wait("Saved: 1"); ui.quit()
        finally:
            ui.close()
        entry["meta"]["application"]["resume_schema"] = "counter.v2"
        (fixture / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "probe", "entries": [entry]}, sort_keys=False))
        if packed:
            pack_deployment(project, pack)
        ui = boot()
        try:
            ui.wait("No applications open")
            ui.open_start(); ui.choose("Counter")
            ui.wait("checkpoint schema is incompatible")
            assert stored(folder)["applications"][0]["resume_schema"] == "counter.v1"
            ui.quit()
        finally:
            ui.close()
        with sqlite3.connect(folder / "workspace.db") as db:
            migrations = db.execute("SELECT id, name, checksum FROM workspace_schema_migrations ORDER BY id").fetchall()
            assert [row[0] for row in migrations] == [1, 2, 3, 4, 5, 6, 7, 8, 9], migrations
            assert migrations[2][1] == "workspace_display_assignments_v1", migrations
            assert migrations[3][1] == "workspace_application_thread_bindings_v1", migrations
            assert migrations[4][1] == "workspace_application_thread_bindings_v2", migrations
            assert migrations[5][1] == "node_workspaces_v1", migrations
            assert migrations[6][1] == "workspace_catalog_order_v1", migrations
            assert migrations[7][1] == "workspace_folder_on_open_v1", migrations
            assert migrations[8][1] == "nested_bee_names_v1", migrations
        print(f"Recovery {'pack' if packed else 'source'}: stable identity, fresh execution, layout, acknowledged state, crash recovery, minimize, close tombstone, manual restore, incompatible schema, nine migrations")

if __name__ == "__main__":
    run(False)
    run(True)
