"""Adversarial app lifecycle scenarios using disposable production compositions."""
from workspace import database_environment
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time
import yaml
from tui_smoke import Desktop, ROOT, RUNTIME

SOURCE = '''local tty = require("tty")
local client = require("client")
local process = require("process")
local channel = require("channel")
local time = require("time")
local function main(value: unknown)
    local launch = client.launch(value)
    if not launch then error("Invalid launch") end
    local events = assert(process.events())
    local input = assert(tty.events())
    assert(tty.start())
    if launch.definition_id == "probe:early" then return end
    if launch.definition_id == "probe:never" then
        process.send(launch.broker_pid, "bee.application.ready", {version = 1, instance_id = launch.instance_id,
            view_id = launch.view_id, launch_token = "forged"})
        time.sleep("10s")
        return
    end
    if launch.definition_id == "probe:delayed" then time.sleep("400ms") end
    local output = assert(tty.surface())
    local width, height = tty.screen_size()
    local function paint()
        local canvas = tty.canvas(width, height)
        canvas:clear(" ")
        canvas:put(1, 1, "READY / " .. launch.definition_id, width)
        assert(output:present(canvas:rows()))
    end
    paint(); client.ready(launch)
    -- A real app PID cannot forge owner operations or affect protected state.
    process.send(launch.workspace_pid, "bee.desktop.command", {version = 1, op = "remove", id = launch.view_id})
    process.send(launch.workspace_pid, "bee.workspace.control", {op = "quit"})
    process.send(launch.broker_pid, "bee.app.request", {version = 1, request_id = "forged", op = "shutdown"})
    while true do
        local selected = channel.select({input:case_receive(), events:case_receive()})
        if not selected.ok then break end
        if selected.channel == events then
            if selected.value.kind == process.event.CANCEL then break end
        elseif selected.value.type == "resize" then
            width, height = selected.value.width, selected.value.height; paint()
        end
        -- Deliberately ignore cooperative close; the broker must escalate.
    end
    output:close(); tty.stop()
end
return {main = main}
'''

def run():
    with tempfile.TemporaryDirectory(prefix="bee-lifecycle-") as temporary:
        project = Path(temporary) / "project"
        shutil.copytree(ROOT / "src", project / "src")
        for name in ["wippy.lock", ".wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        fixture = project / "src/probe"
        fixture.mkdir()
        (fixture / "app.lua").write_text(SOURCE)
        entries = []
        for name in ["early", "never", "delayed", "stubborn"]:
            entries.append({"name": name, "kind": "process.lua", "source": "file://app.lua", "method": "main",
                            "modules": ["tty", "process", "channel", "time"], "imports": {"client": "bee.application:client"},
                            "meta": {"type": "bee.application", "application": {"api_version": 1, "lifetime": "view",
                            "title": name, "revision": "1", "instance_policy": "multiple", "group": "Probe"}}})
        (fixture / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "probe", "entries": entries}, sort_keys=False))
        index = project / "src/_index.yaml"
        doc = yaml.safe_load(index.read_text())
        admission = next(e for e in doc["entries"] if e["name"] == "application_admission")
        admission["bindings"] += [{"definition_id": "probe:" + e["name"], "policies": []} for e in entries]
        index.write_text(yaml.safe_dump(doc, sort_keys=False))
        for name in ["early", "never", "delayed", "stubborn"]:
            with tempfile.TemporaryDirectory(prefix="bee-lifecycle-store-") as directory:
                ui = Desktop(directory, project=project, apps=("probe:" + name,))
                try:
                    if name in {"early", "never"}:
                        ui.wait("Application did not become", timeout=6)
                        assert "No applications open" in ui.screen.display[0]
                        assert "READY /" not in ui.text()
                        ui.resize(ui.width + 1, ui.height)
                        ui.wait("Application did not become")
                    else:
                        ui.wait("READY / probe:" + name)
                        ui.pump(.3)
                        assert ui.process.poll() is None and "READY /" in ui.text()
                        started = time.monotonic()
                        ui.key(b"\x17")
                        ui.wait("No applications open")
                        assert time.monotonic()-started < 1.5
                    ui.quit()
                    print(f"Lifecycle: {name} passed", flush=True)
                finally:
                    ui.close()
        # Retry the same operation identity. First launch is root-generated;
        # every later presenter open uses one fixed request ID in this fixture.
        presenter = project / "src/core/terminal/main.lua"
        text = presenter.read_text()
        anchor = 'request_id = uuid.v7(), op = op, workspace_id = workspace_id, definition_id'
        assert text.count(anchor) == 1, "Presenter retry injection point changed"
        text = text.replace(anchor, 'request_id = op == "open" and "duplicate-probe" or uuid.v7(), op = op, workspace_id = workspace_id, definition_id')
        presenter.write_text(text)
        with tempfile.TemporaryDirectory(prefix="bee-dedup-") as directory:
            ui = Desktop(directory, project=project, apps=("probe:stubborn",))
            try:
                ui.wait("READY / probe:stubborn")
                for _ in range(4):
                    ui.key(b"\x0e")
                assert ui.screen.display[0].count("stubborn") == 2, ui.text()
                ui.key(b"\x17")
                ui.pump(.5)
                ui.key(b"\x0e")
                ui.wait("Original application has stopped")
                assert ui.screen.display[0].count("stubborn") == 1, ui.text()
                ui.quit()
                print("Lifecycle: duplicate open and expired retry passed", flush=True)
            finally:
                ui.close()

        presenter.write_text(text.replace('request_id = op == "open" and "duplicate-probe" or uuid.v7()', 'request_id = uuid.v7()'))
        with tempfile.TemporaryDirectory(prefix="bee-load-") as directory:
            ui = Desktop(directory, project=project, apps=("probe:stubborn",))
            try:
                ui.resize(180, 50)
                ui.wait("READY / probe:stubborn")
                for count in range(1, 17):
                    if count > 1:
                        ui.key(b"\x0e")
                    if count in {1, 8, 16}:
                        def cpu_ticks():
                            fields = Path(f"/proc/{ui.process.pid}/stat").read_text().split(") ", 1)[1].split()
                            return int(fields[11]) + int(fields[12])
                        before = cpu_ticks()
                        started = time.monotonic()
                        ui.pump(.5)
                        percent = 100 * (cpu_ticks()-before) / os.sysconf("SC_CLK_TCK") / (time.monotonic()-started)
                        print(f"Load: {count} idle windows, {percent:.1f}% of one CPU core", flush=True)
                ui.key(b"\x0e")
                ui.wait("Desktop instance limit reached")
                elapsed = ui.quit()
                print(f"Load: 16 instances retained, 17th rejected; exit {elapsed:.3f}s", flush=True)
            finally:
                ui.close()

def detached():
    for packed in (False, True):
        with tempfile.TemporaryDirectory(prefix="bee-detached-") as directory:
            folder = Path(directory)
            project = folder / "project"
            shutil.copytree(ROOT / "src", project / "src")
            shutil.copytree(ROOT / "tests/fixtures/attachments", project / "src/probe")
            broker = project / "src/core/applications/broker.lua"
            code = broker.read_text()
            bootstrap = 'if bootstrap ~= owner or owner == "" then error("Untrusted broker bootstrap") end'
            assert code.count(bootstrap) == 1
            code = code.replace(bootstrap, bootstrap + '\n    if ctx.get("bee.host_owner") == nil then assert(process.registry.register("bee.attachment_probe.host", nil, process.registry.LOCAL)) end')
            code = code.replace(bootstrap, bootstrap + '\n    local fail_renderer_once = ctx.get("bee.test.fail_renderer_once") == true')
            unbind = 'elseif req.op == "unbind" then'
            assert code.count(unbind) == 1
            code = code.replace(unbind, '''elseif req.op == "unbind" and fail_renderer_once then
                        fail_renderer_once = false
                        emit(contract.reply(req.request_id, "unbind", "revoke_failed", "Injected renderer revocation failure"), true)
                    ''' + unbind)
            # Hold one unbind at the real broker until the supervisor has queued
            # detach. This exercises ordering without depending on sleep timing.
            code = code.replace(unbind, unbind + '''
                        local test_payload: unknown = selected.value:payload():data()
                        if type(test_payload) == "table" and test_payload.test_gate == true then
                            local test_supervisor = ctx.get("bee.host_owner")
                            if type(test_supervisor) ~= "string" then error("Missing test supervisor") end
                            local release = assert(process.listen("bee.test.release_unbind", {message = true}))
                            assert(process.send(test_supervisor, "bee.test.unbind_pending", {}))
                            local released = assert(release:receive())
                            assert(released:from() == test_supervisor)
                            process.unlisten(release)
                        end
''')
            broker.write_text(code)
            connections = project / "src/core/host/clients.lua"
            code = connections.read_text()
            gate = 'op = "unbind", recipient ='
            assert code.count(gate) == 1
            connections.write_text(code.replace(gate, 'test_gate = request_id == "queued-render", ' + gate))
            attachment = project / "src/core/applications/attachment.lua"
            code = attachment.read_text()
            anchor = "local _, err = view:revoke(previous.mount)"
            assert code.count(anchor) == 1
            code = code.replace(anchor, '''local function revoke(): (boolean?, string?)
                                    if recipient == previous.recipient then return nil, "Injected revocation failure" end
                                    local ok, failure = view:revoke(previous.mount)
                                    return ok, failure and tostring(failure) or nil
                                end
                                local _, err = revoke()''')
            observer_revoke = "local _, err = view:revoke(previous)"
            assert code.count(observer_revoke) == 1
            code = code.replace("local M = {}", "local M = {}\nlocal fail_observer_revoke_once = true")
            code = code.replace(observer_revoke, """local function revoke_observer(): (boolean?, string?)
                    if fail_observer_revoke_once then
                        fail_observer_revoke_once = false
                        return nil, "Injected observer revocation failure"
                    end
                    local ok, failure = view:revoke(previous)
                    return ok, failure and tostring(failure) or nil
                end
                local _, err = revoke_observer()""")
            observer_remove = "local _, err = view:revoke(mount)"
            assert code.count(observer_remove) == 1
            code = code.replace("local M = {}", "local M = {}\nlocal fail_observer_remove_once = true")
            code = code.replace(observer_remove, """local function revoke_removed_observer(): (boolean?, string?)
                    if fail_observer_remove_once then
                        fail_observer_remove_once = false
                        return nil, "Injected observer detach failure"
                    end
                    local ok, failure = view:revoke(mount)
                    return ok, failure and tostring(failure) or nil
                end
                local _, err = revoke_removed_observer()""")
            attachment.write_text(code)
            host_main = project / "src/core/host/main.lua"
            code = host_main.read_text()
            anchor = 'if not database then error(tostring(database_error)) end'
            assert code.count(anchor) == 1
            code = code.replace(anchor, anchor + '''
    if ctx.get("bee.test.fail_transfer_commit") == true then
        local original_commit = database.assignments.commit
        local injected = false
        database.assignments.commit = function(_, value)
            if not injected then injected = true; return nil, "Injected transfer commit failure" end
            return original_commit(database.assignments, value)
        end
    end''')
            host_main.write_text(code)
            for name in (".wippy.yaml", "wippy.lock"):
                shutil.copy2(ROOT / name, project / name)
            index = project / "src/_index.yaml"
            document = yaml.safe_load(index.read_text())
            # Source exec honors the process host; the pinned pack launcher
            # currently drops --host and still needs a passive terminal entry.
            if not packed:
                document["entries"] = [e for e in document["entries"] if e["kind"] != "terminal.host"]
            for entry in document["entries"]:
                if entry["kind"] == "terminal.host":
                    entry["hide_logs"] = False
            next(e for e in document["entries"] if e["name"] == "application_admission")["bindings"].append({"definition_id": "bee.attachment_probe:app", "policies": []})
            index.write_text(yaml.safe_dump(document, sort_keys=False))
            subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True)
            pack = folder / "detached.wapp"
            if packed:
                subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
            (folder / ".wippy").mkdir(exist_ok=True)
            (project / ".wippy").mkdir(exist_ok=True)
            for mode in ("detached", "failed-open", "terminal", "observation", "host", "clients", "clients-commit"):
                args = [str(RUNTIME), "--console", "run"] + ([str(pack)] if packed else []) + ["attachment-probe", mode, "--host", "bee:workers", "--set", f"registry.history_path={folder}/registry.db"]
                result = subprocess.run(args, cwd=folder if packed else project, capture_output=True, text=True, timeout=20,
                                        env=database_environment(folder, BEE_WORKSPACE_DB=str(folder / f"workspace-{mode}.db")))
                assert result.returncode == 0, f"Attachment mode={mode}, packed={packed}, exit={result.returncode}\n" + result.stdout + result.stderr
                assert f"BEE_ATTACHMENT_COMPLETE:{mode}" in result.stdout + result.stderr, f"Attachment probe did not complete: mode={mode}, packed={packed}\n" + result.stdout + result.stderr
    print("Source/pack: detached Terminal, observer isolation, host restore, client inventory/title/exit updates, detach fencing, renderer replacement/failure, stale generation and queued detach", flush=True)


if __name__ == "__main__":
    run()
    detached()
