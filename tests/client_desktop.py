"""Actual independent desktop owners over native viewport grants."""
from workspace import database_environment
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/wippy")).resolve()


def run(command="desktop-client-probe", shared_store=False, storage_delay=False, launch_exit=False, primary_render_delay=False, copy_exit=False, defaults_probe=False, primary_exit=False, transfer_probe=False):
    with tempfile.TemporaryDirectory(prefix="bee-client-desktop-") as temporary:
        root = Path(temporary)
        project = root / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/desktop_client", project / "src/client_probe")
        if defaults_probe:
            manifest = project / "src/client_probe/_index.yaml"
            document = yaml.safe_load(manifest.read_text())
            next(e for e in document["entries"] if e["name"] == "main")["modules"].append("funcs")
            manifest.write_text(yaml.safe_dump(document, sort_keys=False))
            fixture = project / "src/client_probe/main.lua"
            code = fixture.read_text().replace('local process = require("process")', 'local process = require("process")\nlocal funcs = require("funcs")', 1)
            assert code.count('local function main(mode: string?)') == 1
            code = code.replace('local function main(mode: string?)', """local function main(mode: string?)
    local seeded, seed_error = funcs.call("bee.node:update_appearance", {expected_revision = 0,
        idempotency_key = "fixture-defaults", preferences = {theme = "dos", background = "solid", taskbar = "labels"}})
    assert(not seed_error and type(seeded) == "table" and seeded.ok == true, "Cannot seed node defaults")""", 1)
            code = code.replace('options = {version = 1, desktop_id', 'options = {version = 1, node_defaults = true, desktop_id', 1)
            code = code.replace('local client_scope = scope({"bee:desktop_policy",', 'local client_scope = scope({"bee:client_node_defaults_call_policy", "bee:client_node_defaults_read_policy", "bee:desktop_policy",', 1)
            checkpoint = '    local other_before = assert(store.read(other_store))'
            assert code.count(checkpoint) == 1
            code = code.replace(checkpoint, """    local defaults_ready = false
    for _ = 1, 500 do
        local saved = store.read(other_store)
        if saved and saved.appearance_mode == "inherit" and saved.preferences.theme == "dos" then defaults_ready = true; break end
        time.sleep("10ms")
    end
    assert(defaults_ready, "Fresh display did not inherit seeded node defaults")
""" + checkpoint, 1)
            anchor = '    if not themed then error("Missing themed client state") end\n'
            assert code.count(anchor) == 1
            code = code.replace(anchor, anchor + """    key(resumed_screen, "d")
    local inherited = false
    for _ = 1, 500 do
        local saved = store.read(appearance_store)
        if saved and saved.appearance_mode == "inherit" and saved.preferences.theme == "dos" then inherited = true; break end
        time.sleep("10ms")
    end
    assert(inherited, "Reset state=" .. tostring(assert(store.read(appearance_store)).appearance_mode) .. ":" .. tostring(assert(store.read(appearance_store)).preferences.theme) .. " -- Reset did not commit node defaults and inherit mode: " .. table.concat(assert(resumed_screen:snapshot()).rows, "\\n"))
    key(resumed_screen, "end")
    local customized = false
    for _ = 1, 500 do
        local saved = store.read(appearance_store)
        if saved and saved.appearance_mode == "custom" and saved.preferences.theme == "classic" then customized = true; break end
        time.sleep("10ms")
    end
    assert(customized, "Explicit selection did not restore custom mode")
    local function update_defaults(revision: integer, key: string, theme: string)
        local changed, change_error = funcs.call("bee.node:update_appearance", {expected_revision = revision,
            idempotency_key = key, preferences = {theme = theme, background = "solid", taskbar = "labels"}})
        assert(not change_error and type(changed) == "table" and changed.ok == true, "Cannot update node defaults")
        local applied = false
        for _ = 1, 800 do
            local right_state = store.read(other_store)
            if right_state and right_state.appearance_mode == "inherit" and right_state.preferences.theme == theme then applied = true; break end
            time.sleep("10ms")
        end
        assert(applied, "Inheriting display did not follow a node-default update")
        local left_state = assert(store.read(appearance_store))
        assert(left_state.appearance_mode == "custom" and left_state.preferences.theme == "classic", "Node update changed a custom display")
    end
    update_defaults(1, "live-defaults", "classic")
    wait_text(right_screen, "48;2;12;12;12")
    update_defaults(2, "restore-defaults", "dos")
""")
            fixture.write_text(code)
        if shared_store:
            fixture_manifest = project / "src/client_probe/_index.yaml"
            data = yaml.safe_load(fixture_manifest.read_text())
            next(entry for entry in data["entries"] if entry["name"] == "right_policy")["policy"]["resources"] = ["bee.client.db:left"]
            fixture_manifest.write_text(yaml.safe_dump(data, sort_keys=False))
        shutil.copytree(ROOT / "tests/fixtures/client_storage/client_database", project / "src/client_databases")
        databases = project / "src/client_databases/_index.yaml"
        database_entries = yaml.safe_load(databases.read_text())
        database_entries["entries"].append({"name": "observer", "kind": "db.sql.sqlite", "file": "${env:bee:client_db_path}.observer"})
        database_entries["entries"].append({"name": "status", "kind": "db.sql.sqlite", "file": "${env:bee:client_db_path}.status"})
        databases.write_text(yaml.safe_dump(database_entries, sort_keys=False))
        config = project / "src/_index.yaml"
        value = yaml.safe_load(config.read_text())
        value["entries"].append({"name": "client_db_path", "kind": "env.variable", "storage": "bee:workspace_environment",
                                 "variable": "BEE_CLIENT_DB", "default": str(root / "build-client.db"), "readonly": True})
        config.write_text(yaml.safe_dump(value, sort_keys=False))
        if command in ("thread-status-probe", "retained-supervisor-probe"):
            # The disposable presenter copy stamps each frame with its PID.
            # This lets the fixture distinguish an F12 replacement from the
            # retained output of the viewport it replaced.
            presenter = project / "src/core/terminal/main.lua"
            source = presenter.read_text()
            label = '"Workspace " .. names.label(workspace_id)'
            assert source.count(label) == 1, "unexpected terminal presenter label anchor"
            presenter.write_text(source.replace(label, label + ' .. " " .. tostring(process.pid()):sub(-12)', 1))
        if primary_render_delay:
            lifecycle = project / "src/core/launch/desktop_lifecycle.lua"
            code = lifecycle.read_text().replace('local M = {}', 'local M = {}\nlocal probe_held_renderer = false', 1)
            anchor = '    child.pending, child.phase, child.deadline = uuid.v7(), "render", time.after("10s")\n'
            assert code.count(anchor) == 1
            code = code.replace(anchor, anchor + '    if child.id == state.default_id and not probe_held_renderer then probe_held_renderer = true; return end\n', 1)
            lifecycle.write_text(code)
            fixture = project / "src/client_probe/retained.lua"
            code = fixture.read_text()
            anchor = '    local before_rejoin = assert(extra_screen:snapshot()).rows[1]'
            code = code.replace(anchor, '''    local primary_before = assert(first_screen:snapshot()).rows[1]
    assert(first_screen:send({type = "key", key = "f12", key_type = "f12", action = "press"}))
    time.sleep("100ms")
''' + anchor, 1)
            anchor = '    assert(replaced, "Additional desktop presenter was not replaced")'
            code = code.replace(anchor, anchor + '''
    local paused_primary = false
    for _ = 1, 1500 do
        local frame = first_screen:snapshot()
        if frame and table.concat(frame.rows, "\\n"):find("Desktop paused", 1, true) then paused_primary = true; break end
        time.sleep("10ms")
    end
    assert(paused_primary, "Primary renderer timeout did not preserve its paused desktop")
    assert(first_screen:send({type = "key", key = "f12", key_type = "f12", action = "press"}))
    local primary_rejoined = false
    for _ = 1, 500 do
        local frame = first_screen:snapshot()
        if frame and frame.rows[1] ~= primary_before and table.concat(frame.rows, "\\n"):find("OWNER_alive_OK", 1, true)
            and not table.concat(frame.rows, "\\n"):find("Desktop paused", 1, true) then primary_rejoined = true; break end
        time.sleep("10ms")
    end
    assert(primary_rejoined, "Primary desktop did not recover after the withheld renderer reply")
''', 1)
            fixture.write_text(code)
        if primary_exit:
            client = project / "src/core/client/main.lua"
            code = client.read_text()
            anchor = '                    if selected.channel == copy_results and sender == presenter then\n'
            assert code.count(anchor) == 1
            client.write_text(code.replace(anchor, anchor + '                        if bootstrap.desktop_id == nil then error("Injected initial display crash") end\n'))
            fixture = project / "src/client_probe/retained.lua"
            code = fixture.read_text().replace('    local catalogs = assert(process.listen("bee.retained.desktops_result", {message = true}))',
                '    local catalogs = assert(process.listen("bee.retained.desktops_result", {message = true}))\n    local copied = assert(process.listen("bee.retained.copied", {message = true}))')
            anchor = '    local before_rejoin = assert(extra_screen:snapshot()).rows[1]'
            injection = r'''    assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id,
        desktop_id = desktop_id, request_id = "initial-display-crash", recipient = first, op = "copy"}))
    local crashed = channel.select({copied:case_receive(), time.after("3s"):case_receive()})
    assert(crashed.ok and crashed.channel == copied, "Initial display crash killed workspace or stranded copy")
    local crash_message = crashed.value
    assert(tostring(crash_message:from()) == supervisor)
    local crash_value: unknown = crash_message:payload():data()
    assert(type(crash_value) == "table" and crash_value.request_id == "initial-display-crash"
        and type(crash_value.error) == "string" and crash_value.error ~= "", "Crash did not settle copy uncertainty")
    command(extra_screen, "printf 'SURVIVING_%s_OK\\n' \"$bee_extra\"")
    wait_text(extra_screen, "SURVIVING_separate_OK")
    storage("list", nil, "OK", 2)
    process.terminate(first)
    local physical_deadline = time.after("3s")
    while true do
        local stopped = channel.select({events:case_receive(), physical_deadline:case_receive()})
        assert(stopped.ok and stopped.channel == events, "Crashed display physical client did not exit")
        assert(tostring(stopped.value.from) ~= supervisor, "Initial display crash stopped supervisor")
        if stopped.value.kind == process.event.EXIT and tostring(stopped.value.from) == first then break end
    end
    first_screen:close()
    activate(desktop_id, "")
    first, first_screen = attach()
    command(first_screen, "printf 'REACTIVATED_%s_OK\\n' \"$bee_owner\"")
    wait_text(first_screen, "REACTIVATED_alive_OK")
'''
            assert anchor in code
            fixture.write_text(code.replace(anchor, injection + anchor, 1))
        if copy_exit:
            client = project / "src/core/client/main.lua"
            code = client.read_text()
            anchor = '                    if selected.channel == copy_results and sender == presenter then\n'
            assert code.count(anchor) == 1
            client.write_text(code.replace(anchor, anchor + '                        if bootstrap.desktop_id == string.rep("f", 32) then return end\n'))
            fixture = project / "src/client_probe/retained.lua"
            code = fixture.read_text().replace('    local catalogs = assert(process.listen("bee.retained.desktops_result", {message = true}))',
                '    local catalogs = assert(process.listen("bee.retained.desktops_result", {message = true}))\n    local copied = assert(process.listen("bee.retained.copied", {message = true}))')
            anchor = '    activate(extra_id, "")\n'
            injection = '''    local copy_id = string.rep("f", 32)
    storage("allocate", copy_id, "OK", 0)
    activate(copy_id, "")
    local failed_display, failed_screen = attach("control", copy_id)
    local function copy(recipient: string, target: string, correlation: string, failed: boolean)
        assert(process.send(supervisor, "bee.retained.request", {version = 1, workspace_id = workspace_id,
            desktop_id = target, request_id = correlation, recipient = recipient, op = "copy"}))
        local result = channel.select({copied:case_receive(), time.after("3s"):case_receive()})
        assert(result.ok and result.channel == copied, "Copy result was stranded")
        local message = result.value
        assert(tostring(message:from()) == supervisor)
        local value: unknown = message:payload():data()
        assert(type(value) == "table" and value.request_id == correlation and value.selected == false
            and value.text == "" and type(value.error) == "string")
        assert((value.error ~= "") == failed, "Unexpected copy failure state")
    end
    copy(failed_display, copy_id, "copy-exit", true)
    copy(first, desktop_id, "copy-after-exit", false)
    process.terminate(failed_display)
    local failed_timeout = time.after("3s")
    while true do
        local stopped = channel.select({events:case_receive(), failed_timeout:case_receive()})
        assert(stopped.ok and stopped.channel == events, "Failed copy display did not exit")
        if stopped.value.kind == process.event.EXIT and tostring(stopped.value.from) == failed_display then break end
        assert(tostring(stopped.value.from) ~= supervisor, "Copy exit killed supervisor")
    end
    failed_screen:close()
'''
            assert anchor in code
            fixture.write_text(code.replace(anchor, injection + anchor, 1))
        if launch_exit:
            client = project / "src/core/client/main.lua"
            code = client.read_text()
            anchor = '                            if launch_pending and reply.request_id == launch_pending.request_id and (reply.op == "open" or reply.op == "focus") then\n'
            assert code.count(anchor) == 1
            client.write_text(code.replace(anchor, anchor + '                                if bootstrap.desktop_id == string.rep("e", 32) then return end\n'))
            fixture = project / "src/client_probe/retained.lua"
            code = fixture.read_text()
            anchor = '    activate(extra_id, "")\n'
            injection = '''    local fault_id = string.rep("e", 32)
    storage("allocate", fault_id, "OK", 0)
    activate(fault_id, "")
    local failed_display, failed_screen = attach("control", fault_id)
    assert(launch(failed_display, "terminal", {"bash", "-c", "printf committed > fault-launch-evidence; exec bash -i"}, fault_id) == "UNCERTAIN",
        "Lost launch result must preserve uncertainty")
    assert(launch(first, "missing-command", {}) == "INVALID_ARGUMENT", "Dead desktop left launch admission busy")
    process.terminate(failed_display)
    local failed_timeout = time.after("3s")
    while true do
        local stopped = channel.select({events:case_receive(), failed_timeout:case_receive()})
        assert(stopped.ok and stopped.channel == events, "Failed desktop display did not exit")
        if stopped.value.kind == process.event.EXIT and tostring(stopped.value.from) == failed_display then break end
        assert(tostring(stopped.value.from) ~= supervisor, "Desktop exit killed supervisor")
    end
    failed_screen:close()
'''
            assert anchor in code
            fixture.write_text(code.replace(anchor, injection + anchor, 1))
        if storage_delay:
            operations = project / "src/core/client/desktop_storage.lua"
            code = operations.read_text().replace('local security = require("security")', 'local security = require("security")\nlocal time = require("time")')
            code = code.replace('function M.allocate(value: unknown): Reply', 'function M.allocate(value: unknown): Reply\n    if type(value) == "table" and value.desktop_id == string.rep("c", 32) then time.sleep("6s") end')
            operations.write_text(code)
            manifest = project / "src/core/client/_index.yaml"
            values = yaml.safe_load(manifest.read_text())
            for entry in values["entries"]:
                if entry.get("source") == "file://desktop_storage.lua": entry["modules"].append("time")
            manifest.write_text(yaml.safe_dump(values, sort_keys=False))
            fixture = project / "src/client_probe/retained.lua"
            code = fixture.read_text()
            code = code.replace('    local first, first_screen = attach()', '''    assert(process.send(supervisor, "bee.retained.desktops", {version = 1, workspace_id = workspace_id,
        request_id = "slow-allocation", op = "allocate", desktop_id = string.rep("c", 32)}))
    storage("list", nil, "BUSY", 0)
    local first, first_screen = attach()''', 1)
            code = code.replace('    wait_text(first_screen, "OWNER_alive_OK")', '''    wait_text(first_screen, "OWNER_alive_OK")
    local slow = channel.select({catalogs:case_receive(), time.after("6s"):case_receive()})
    assert(slow.ok and slow.channel == catalogs, "Storage timeout did not reply")
    local slow_message = slow.value
    assert(tostring(slow_message:from()) == supervisor)
    local slow_data: unknown = slow_message:payload():data()
    assert(type(slow_data) == "table" and slow_data.request_id == "slow-allocation"
        and slow_data.code == "UNAVAILABLE" and slow_data.desktop_id == string.rep("c", 32))
    time.sleep("1500ms")
    storage("allocate", string.rep("a", 32), "OK", 0)''', 1)
            fixture.write_text(code)
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, project / name)
        lint = subprocess.run([str(RUNTIME), "lint", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"], cwd=project, capture_output=True, text=True)
        assert lint.returncode == 0, lint.stdout + lint.stderr
        pack = root / "client-desktop.wapp"
        subprocess.run([str(RUNTIME), "pack", str(pack)], cwd=project, check=True)
        for packed in (False, True):
            folder = root / ("pack" if packed else "source")
            folder.mkdir()
            # Optional subsystem stores use .wippy defaults inside this disposable host.
            ((folder if packed else project) / ".wippy").mkdir(exist_ok=True)
            args = [str(RUNTIME), "--console", "run"] + ([str(pack)] if packed else [])
            args += [command] + (["transfer"] if transfer_probe else (["shared-store"] if shared_store else [])) + [ "--host", "bee:workers", "--set", f"registry.history_path={folder / 'registry.db'}"]
            try:
                result = subprocess.run(args, cwd=folder if packed else project, capture_output=True, text=True, timeout=40,
                                        env=database_environment(folder, BEE_CLIENT_DB=str(folder / "client.db")))
            except subprocess.TimeoutExpired as error:
                output = error.stdout or b""
                errors = error.stderr or b""
                raise AssertionError(f"Desktop fixture timed out; stdout={output!r}; stderr={errors!r}") from error
            logs = result.stdout + result.stderr
            assert result.returncode == 0, logs
            marker = {
                "desktop-client-probe": "DESKTOP_TRANSFER_PROBE_COMPLETE" if transfer_probe else "DESKTOP_CLIENT_PROBE_COMPLETE",
                "retained-supervisor-probe": "RETAINED_SUPERVISOR_PROBE_COMPLETE",
                "thread-status-probe": "THREAD_STATUS_PROBE_COMPLETE",
            }[command]
            assert marker in logs, logs
            if launch_exit:
                assert ((folder if packed else project) / "fault-launch-evidence").read_text() == "committed"
            if command == "retained-supervisor-probe":
                assert "shutdown error" not in logs and "is failed" not in logs, logs
    if transfer_probe:
        print("Display transfer source/pack: real window menu, exact retained shell PID/state, neighbor unaffected, client layouts and source F12")
        return
    if command == "retained-supervisor-probe":
        print(f"Retained supervisor source/pack (slow storage={storage_delay}, launch exit={launch_exit}, primary delay={primary_render_delay}, copy exit={copy_exit}, primary exit={primary_exit}): authorized catalog/allocation and retry, additional activation/replay, independent Terminals, additional F12/save/reactivation with live shell, startup/admission, forged sender denial, controller exclusion, observer/retired launch denial, literal command launch and broker identity, display EXIT revocation, explicit detach/rejoin, same shell, retained display close/reactivation")
        return
    if command == "thread-status-probe":
        print("Bound thread status source/pack: host-authorized association, visible owner-derived badge, F12 and fresh-client retention")
        return
    print(f"Desktop clients source/pack ({'shared store' if shared_store else 'independent appearance'}): separate displays, qualified tabs, PTY isolation, F12 dialogs, import retry, retained-terminal restart, isolated Settings and negotiated host shutdown")


if __name__ == "__main__":
    run()
    run(shared_store=True)
    run(command="retained-supervisor-probe")
    run(command="retained-supervisor-probe", storage_delay=True)
    run(command="retained-supervisor-probe", launch_exit=True)
    run(command="retained-supervisor-probe", primary_render_delay=True)
    run(command="retained-supervisor-probe", copy_exit=True)
    run(command="retained-supervisor-probe", primary_exit=True)
    run(command="thread-status-probe")
