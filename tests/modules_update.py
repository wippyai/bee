"""Source/pack acceptance for saved parameter hydration on Hub updates."""
import tempfile
from pathlib import Path

from tui_smoke import Desktop
from workspace import fixture_workspace, pack_fixture


FACADE = r'''
local time = require("time")
local installed_reads = 0
local inspections = 0
local function handle(raw: unknown): {[string]: unknown}
    if type(raw) ~= "table" then return {ok = false, replayed = false} end
    if raw.operation == "catalog" then
        return {ok = true, replayed = false, value = {total = 1, items = {{
            component = "acme/example", title = "Update fixture", description = "Saved configuration fixture",
            latest_version = "2.0.0"}}}}
    elseif raw.operation == "updates" then
        return {ok = true, replayed = false, value = {modules = {}, bee_update = {
            installed_version = "", available_version = "", update_available = false,
            needs_new_binary = false, reason = ""}, catalog_error = ""}}
    elseif raw.operation == "details" then
        return {ok = true, replayed = false, value = {component = "acme/example", title = "Update fixture",
            description = "Saved configuration fixture", readme = "# Update fixture", page = 1, total_versions = 1,
            versions = {{version = "2.0.0", yanked = false}}}}
    elseif raw.operation == "installed" then
        installed_reads = installed_reads + 1
        if installed_reads == 1 then
            -- Let the client change the selected pane while this read is in flight.
            time.sleep("2s")
        elseif installed_reads == 2 then
            return {ok = false, replayed = false, code = "READ", message = "temporary installed inventory failure"}
        elseif installed_reads == 3 then
            -- Keep the retry visibly pending before requirements is attempted.
            time.sleep("0.5s")
        end
        local stale = installed_reads == 1
        return {ok = true, replayed = false, value = {modules = {{component = "acme/example", version = "1.0.0",
            source = "hub", direct = true, used_by = {}}}, roots = {{
            id = "bee.hub.deps:cc95b0f7498a74222c0f5db968f6ff26b78e569d19ce551d4c052d26139818b1",
            component = "acme/example", version = "1.0.0", managed = true, parameters = {
                {name = "example:enabled", value = stale and false or true},
                {name = "example:name", value = stale and "stale" or "saved"},
                {name = "example:config", value = {mode = stale and "stale" or "saved", retries = stale and 99 or 3}},
            }}}}}
    elseif raw.operation == "inspect" then
        inspections = inspections + 1
        local values: {[string]: unknown} = {}
        for _, parameter in ipairs(raw.request.parameters or {}) do values[parameter.name] = parameter.value end
        if inspections == 1 then
            assert(values["example:enabled"] == true, "saved boolean parameter was not hydrated")
            assert(values["example:name"] == "saved", "saved string parameter was not hydrated")
            assert(values["example:config"] ~= nil and values["example:config"].mode == "saved"
                and values["example:config"].retries == 3, "saved object parameter was not hydrated")
        else
            assert(values["example:enabled"] == nil or values["example:enabled"] == true,
                "saved boolean parameter lost its type")
        end
        assert(values["example:name"] == nil or values["example:name"] == "saved" or values["example:name"] == "changed",
            "saved string parameter changed unexpectedly")
        local config = values["example:config"]
        assert(config == nil or (config.mode == "saved" and config.retries == 3), "saved object parameter changed unexpectedly")
        local function requirement(id: string, default: unknown): {[string]: unknown}
            local selected = values[id] ~= nil
            return {id = id, has_default = true, default = default, has_selected = selected,
                selected = selected and values[id] or nil, targets = {}}
        end
        return {ok = true, replayed = false, value = {component = "acme/example", version = raw.request.version,
            digest = string.rep("c", 64), requirements = {missing = {}, requirements = {
                requirement("example:enabled", false), requirement("example:name", "default"),
                requirement("example:config", {mode = "default"}),
            }}}}
    elseif raw.operation == "plan" then
        assert(raw.request.action == "update", "expected an update plan")
        local values: {[string]: unknown} = {}
        for _, parameter in ipairs(raw.request.parameters or {}) do values[parameter.name] = parameter.value end
        assert(values["example:enabled"] == nil, "cleared boolean override was restored")
        assert(values["example:name"] == "changed", "edited string parameter was not submitted")
        assert(values["example:config"] ~= nil and values["example:config"].mode == "saved"
            and values["example:config"].retries == 3, "untouched object parameter was not preserved")
        return {ok = true, replayed = false, value = {request = raw.request, digest = string.rep("a", 64),
            ready = true, base_revision = 1, modules = {}, missing = {}, migrations = {}, starts = {}, capabilities = {}}}
    end
    return {ok = false, replayed = false, code = "FIXTURE", message = "unsupported update fixture operation"}
end
return {handle = handle}
'''


SELF_UPDATE_FACADE = r'''
local function handle(raw: unknown): {[string]: unknown}
    if type(raw) ~= "table" then return {ok = false, replayed = false} end
    if raw.operation == "catalog" then
        return {ok = true, replayed = false, value = {total = 0, items = {}}}
    elseif raw.operation == "installed" then
        return {ok = true, replayed = false, value = {version = 1, modules = {
            {component = "bee/bee", version = "1.0.0", source = "hub", direct = true, used_by = {}},
            {component = "bee/application", version = "1.0.0", source = "hub", direct = false, used_by = {"bee/bee"}},
        }, roots = {{id = "bee:deployment", component = "bee/bee", version = "1.0.0", managed = false, parameters = {
            {name = "bee:target", value = {channel = "stable"}},
        }}}}}
    elseif raw.operation == "updates" then
        return {ok = true, replayed = false, value = {modules = {
            {component = "bee/bee", installed_version = "1.0.0", available_version = "2.0.0", update_available = true},
            {component = "bee/application", installed_version = "1.0.0", available_version = "2.0.0", update_available = true},
        }, bee_update = {installed_version = "1.0.0", available_version = "2.0.0", update_available = true,
            needs_new_binary = false, reason = ""}, catalog_error = ""}}
    elseif raw.operation == "plan" then
        local request = raw.request
        assert(request.action == "update" and request.component == "bee/bee" and request.version == "2.0.0",
            "Bee update did not plan the host deployment root")
        assert(#request.parameters == 1 and request.parameters[1].name == "bee:target"
            and request.parameters[1].value.channel == "stable", "Bee update did not preserve host root parameters")
        return {ok = true, replayed = false, value = {request = request, digest = string.rep("a", 64), ready = true,
            base_revision = 12, modules = {
                {component = "bee/bee", version = "2.0.0", previous_version = "1.0.0", change = "update"},
                {component = "bee/application", version = "2.0.0", previous_version = "1.0.0", change = "update"},
            }, missing = {}, migrations = {}, starts = {}, capabilities = {}}}
    end
    return {ok = false, replayed = false, code = "FIXTURE", message = "unsupported self-update operation"}
end
return {handle = handle}
'''


def exercise(project, packed, pack):
    with tempfile.TemporaryDirectory(prefix="bee-modules-update-") as directory:
        (Path(directory) / ".wippy").mkdir()
        ui = Desktop(directory, packed=packed, project=project, deployment=pack, apps=("bee.hub.modules.app:app",))
        try:
            ui.resize(150, 40)
            ui.wait("MODULES", timeout=20)
            ui.resize(160, 40)
            ui.wait("Update fixture")
            ui.key(b"\x1b[B")
            ui.key(b"\r")
            ui.wait("Version 2.0.0")
            ui.key(b"u")
            # The first inventory read is delayed. Changing panes retires its
            # generation, so the late response cannot hydrate stale state.
            ui.key(b"v")
            ui.key(b"\x1b[B")
            ui.wait("Version 2.0.0")
            ui.key(b"p")
            ui.wait("installed settings are still loading")
            ui.key(b"u")
            ui.wait("READ: temporary installed inventory failure")
            ui.key(b"p")
            ui.wait("installed settings could not be read")
            ui.key(b"u")
            ui.wait("Installed settings loaded")
            ui.key(b"e")
            ui.wait("example:enabled")
            # Delete clears the saved boolean override and re-inspects.
            ui.key(b"\x1b[3~")
            ui.wait("example:enabled · Default")
            ui.key(b"\x1b[B")
            ui.key(b"\r")
            ui.wait('"saved"')
            ui.key(b"\x7f" * 7 + b'"changed"\r')
            ui.wait("Selected")
            ui.key(b"p")
            ui.wait("Ready for confirmation")
            ui.quit()
        except Exception:
            (Path(directory) / "bee-modules-update-failure.raw").write_bytes(ui.raw)
            raise
        finally:
            ui.close()


def exercise_self_update(project, packed, pack):
    with tempfile.TemporaryDirectory(prefix="bee-modules-self-update-") as directory:
        (Path(directory) / ".wippy").mkdir()
        ui = Desktop(directory, packed=packed, project=project, deployment=pack, apps=("bee.hub.modules.app:app",))
        try:
            ui.wait("MODULES", timeout=20)
            for y, line in enumerate(ui.screen.display, 1):
                if "Installed" in line:
                    x = line.index("Installed") + 1
                    ui.mouse(0, x, y)
                    ui.mouse(0, x, y, True)
                    break
            else:
                raise AssertionError(f"Installed tab is missing\n{ui.text()}")
            ui.wait("MODULES  INSTALLED")
            ui.wait("bee/bee")
            ui.wait("Hub 2.0.0")
            ui.wait("Update Bee")
            ui.key(b"u")
            ui.wait("Ready for confirmation")
            assert "update  bee/bee  2.0.0" in ui.text(), ui.text()
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            assert "update  bee/bee  2.0.0" in ui.text() and "update  bee/application  2.0.0" in ui.text(), ui.text()
            ui.quit()
        except Exception:
            (Path(directory) / "bee-modules-self-update-failure.raw").write_bytes(ui.raw)
            raise
        finally:
            ui.close()


def main():
    with fixture_workspace(unit_tests=False) as project:
        (project / "modules/hub/src/binding/facade.lua").write_text(FACADE)
        manifest = project / "modules/hub/src/binding/_index.yaml"
        manifest.write_text(manifest.read_text().replace("modules: [security, funcs]", "modules: [security, funcs, time]", 1))
        pack = project / "modules-update-deployment"
        pack_fixture(project, pack)
        exercise(project, False, pack)
        exercise(project, True, pack)
        (project / "modules/hub/src/binding/facade.lua").write_text(SELF_UPDATE_FACADE)
        pack = project / "modules-self-update-deployment"
        pack_fixture(project, pack)
        exercise_self_update(project, False, pack)
        exercise_self_update(project, True, pack)
    print("Modules source/pack update: delayed and failed inventory reads, retry fencing, saved typed values, edit/clear preservation and update planning pass")


if __name__ == "__main__":
    main()
