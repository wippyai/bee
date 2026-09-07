"""Adversarial app lifecycle scenarios using disposable production compositions."""
from pathlib import Path
import os
import shutil
import tempfile
import time
import yaml
from tui_smoke import Desktop, ROOT

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
        text = presenter.read_text().replace('request_id = uuid.v7(), op = op, definition_id', 'request_id = op == "open" and "duplicate-probe" or uuid.v7(), op = op, definition_id')
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

if __name__ == "__main__":
    run()
