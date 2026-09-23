"""Source/pack Modules input acceptance with deterministic fixture Hub replies.

The real facade and publication boundary are covered by hub-manage-check.
This fixture exercises the actual broker, app process, presenter and keyboard.
"""
import re
import tempfile
import time
from pathlib import Path
import yaml

from tui_smoke import Desktop
from workspace import fixture_workspace, pack_fixture, registry_entries


FACADE = '''
local recovered = false
local function handle(raw: unknown): {[string]: unknown}
    if type(raw) ~= "table" then return {ok = false, replayed = false} end
    if raw.operation == "catalog" then
        return {ok = true, replayed = false, value = {total = 1, items = {{
            component = "bee/example", title = "Preview fixture", description = "Packaged module",
            latest_version = "1.0.0"}}}}
    elseif raw.operation == "details" then
        return {ok = true, replayed = false, value = {component = "bee/example", title = "Preview fixture",
            description = "Packaged module", readme = "# Fixture guide\\nRead this before installing.\\nPackage usage and configuration.", page = 1, total_versions = 2,
            versions = {{version = "1.0.0", yanked = false}, {version = "0.9.0", yanked = false}}}}
    elseif raw.operation == "inspect" then
        local chosen = false
        for _, parameter in ipairs(raw.request.parameters or {}) do
            if parameter.name == "example:enabled" then
                assert(parameter.value == true, "requirement editor lost boolean type")
                chosen = true
            end
        end
        return {ok = true, replayed = false, value = {component = "bee/example", version = raw.request.version,
            digest = string.rep("c", 64), requirements = {missing = {}, requirements = {
                {id = "example:enabled", has_default = true, default = false, has_selected = chosen, selected = chosen,
                    targets = {{entry = "example:config", path = ".enabled"}}}}}}}
    elseif raw.operation == "plan" then
        local missing = {}
        if raw.request.action ~= "uninstall" then
            local configured = false
            for _, parameter in ipairs(raw.request.parameters or {}) do
                if parameter.name == "dependency:directory" then
                    assert(parameter.value == "data", "missing requirement editor lost exact value")
                    configured = true
                end
            end
            if not configured then missing = {"dependency:directory"} end
        end
        local normalized = raw.request
        if raw.request.action == "uninstall" then normalized = {action = "uninstall", component = raw.request.component,
            migration_policy = raw.request.migration_policy, version = "", parameters = {}} end
        return {ok = true, replayed = false, value = {request = normalized,
            digest = string.rep("a", 64), ready = #missing == 0, base_revision = 1,
            modules = {}, missing = missing, migrations = raw.request.action == "uninstall" and {{id = "fixture:rollback", target_db = "fixture:db"}} or {}, starts = {}, capabilities = {
                "fixture:01", "fixture:02", "fixture:03", "fixture:04", "fixture:05", "fixture:06",
                "fixture:07", "fixture:08", "fixture:09", "fixture:10", "fixture:11", "fixture:12",
                "fixture:last"}}}
    elseif raw.operation == "status" then
        local rows = {}
        for index = 1, 12 do rows[index] = {id = "recovery:step" .. tostring(index), target_db = "recovery:db", module = "bee/recovery", status = "applied"} end
        local receipt = {digest = string.rep("b", 64), action = "install", component = "bee/recovery",
            baseline_revision = 42, state = recovered and "complete" or "recovery_required",
            message = recovered and "Fixture recovery confirmed" or "Schema committed; receipt pending",
            request = {action = "install", component = "bee/recovery", version = "2.0.0", parameters = {{name = "recovery:settings", value = {enabled = true}}}, migration_policy = "up"},
            migration_work = {rows = rows}}
        if raw.expected_digest then
            assert(raw.expected_digest == string.rep("b", 64), "cold recovery status lost receipt digest")
            return {ok = true, replayed = false, value = receipt}
        end
        return {ok = true, replayed = false, value = {operations = {receipt}, page = 1, total = 1, page_size = 25}}
    elseif raw.operation == "apply" then
        if raw.expected_digest == string.rep("b", 64) then
            assert(type(raw.request) == "table" and raw.request.component == "bee/recovery"
                and raw.request.version == "2.0.0" and raw.request.migration_policy == "up"
                and raw.request.parameters[1].value.enabled == true, "recovery changed stored request")
            recovered = true
            return {ok = true, replayed = true, value = {state = "complete", message = "Fixture recovery confirmed"}}
        end
        assert(raw.expected_digest == string.rep("a", 64), "confirmation lost the displayed digest")
        if raw.request.action == "uninstall" then
            assert(raw.request.migration_policy == "down", "rollback selection was lost")
            return {ok = true, replayed = false, value = {state = "complete", message = "Fixture rollback confirmed"}}
        end
        return {ok = true, replayed = false, value = {state = "complete", message = "Fixture confirmation received"}}
    end
    return {ok = false, replayed = false, code = "FIXTURE", message = "No fixture mutation"}
end
return {handle = handle}
'''


def exercise(project, packed, pack):
    with tempfile.TemporaryDirectory(prefix="bee-modules-ui-") as directory:
        (Path(directory) / ".wippy").mkdir()
        ui = Desktop(directory, packed=packed, project=project, deployment=pack, apps=("bee.modules:app",))
        try:
            ui.wait("MODULES", timeout=20)
            ui.wait("Preview fixture", timeout=10)
            # Cold recovery: no package selection or plan exists in this app.
            ui.key(b"o")
            ui.wait("MODULES  OPERATIONS")
            ui.wait("bee/recovery")
            ui.key(b"\x1b[B")
            ui.wait("Schema committed; receipt pending")
            ui.key(b"\x1b[6~" * 8)
            ui.wait("recovery:step12")
            ui.key(b"\r")
            ui.wait("Review recovery")
            ui.wait('"enabled":true')
            ui.key(b"\x1b[B" * 24)
            ui.wait("recovery:step12")
            assert "Fixture recovery confirmed" not in ui.text(), "review dispatched recovery"
            ui.key(b"\x1b")
            ui.wait("MODULES  OPERATIONS")
            ui.wait("recovery_required")
            ui.key(b"\r")
            ui.wait("Review recovery")
            ui.key(b"\x1b[24~")
            ui.wait("Review recovery", timeout=8)
            ui.resize(60, 20)
            ui.wait("Confirm recovery")
            ui.key(b"\r")
            ui.wait("Fixture recovery confirmed")
            ui.wait("Receipt state: complete")
            ui.key(b"r")
            ui.wait("Fixture recovery confirmed")
            ui.resize(100, 30)
            ui.key(b"\x1b")
            ui.wait("Keyword: bee")
            ui.key(b"K")
            ui.wait("Filter by keyword")
            ui.key(b"\x7f\x7f\x7f\r")
            ui.wait("Keyword: all")
            ui.key(b"/")
            ui.key("terminal café".encode())
            ui.key(b"\x7f\r")
            ui.wait("Search: terminal caf")
            ui.key(b"\x1b[B")
            ui.key(b"\r")
            ui.wait("Packaged module")
            ui.wait("1.0.0")
            ui.key(b"h")
            ui.wait("Fixture guide")
            ui.wait("Read this before installing.")
            ui.key(b"v")
            ui.wait("1.0.0")
            ui.key(b"e")
            ui.wait("example:enabled")
            ui.wait("Default")
            ui.wait("example:config .enabled")
            ui.key(b"\r")
            ui.wait("Configure package")
            ui.wait("false")
            ui.key(b"\x7f" * 5 + b"true\r")
            ui.wait("Selected")
            ui.key(b"\x1b[3~")
            ui.wait("Default")
            ui.wait("false")
            ui.key(b"\x1b[24~")
            ui.wait("example:enabled")
            ui.key(b"v")
            ui.wait("1.0.0")
            # Regression: j navigation previously swallowed this JSON shortcut.
            ui.key(b"j")
            ui.wait("Parameter name (namespace:name)")
            ui.key(b"example:settings\r")
            ui.wait("Configure package")
            ui.wait("example:settings")
            ui.key(b'{"enabled": true, "title": "two words"}\r')
            ui.key(b"j")
            ui.wait("Parameter name (namespace:name)")
            ui.key(b"\x1b")
            ui.key(b"p")
            ui.wait("Required: dependency:directory")
            ui.key(b"e")
            ui.wait("Configure package")
            ui.wait("dependency:directory")
            ui.key(b'"data"\r')
            ui.key(b"p")
            ui.wait("Ready for confirmation")
            assert "Fixture confirmation received" not in ui.text(), "planning applied the operation"
            ui.key(b"\x1b[B" * 20)
            ui.wait("fixture:last")
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            ui.key(b"\x1b")
            ui.wait("MODULES  PLAN")
            assert "Fixture confirmation received" not in ui.text(), "cancelling confirmation applied the operation"
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            ui.key(b"\r")
            ui.wait("Fixture confirmation received")
            ui.wait("Receipt state: complete")
            assert "Applying measured plan" not in ui.text(), "completed operation retained pending status"
            ui.key(b"\x1b")
            ui.key(b"\x1b[B\r")
            ui.wait("Packaged module")
            ui.key(b"x")
            ui.wait("Roll back")
            for y, line in enumerate(ui.screen.display, 1):
                x = line.find("Roll back")
                if x >= 0:
                    ui.mouse(0, x + 3, y)
                    break
            else:
                raise AssertionError("rollback policy button is not visible")
            ui.key(b"p")
            ui.wait("Migrations · policy down")
            ui.wait("fixture:rollback")
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            assert "Fixture rollback confirmed" not in ui.text(), "rollback ran before confirmation"
            ui.key(b"\r")
            ui.wait("Fixture rollback confirmed")
            ui.key(b"\x1b[24~")
            ui.wait("MODULES", timeout=8)
            ui.resize(60, 20)
            ui.wait("MODULES")
            ui.quit()
        except Exception:
            Path("/tmp/bee-modules-ui-failure.raw").write_bytes(ui.raw)
            raise
        finally:
            ui.close()


def install_receipt(ui, packed, pack):
    """Wait for the confirmed installation's receipt and explain a refusal.

    A packed deployment carries Bee's own modules only as locked packs, so the
    installation re-resolves every locked bee/* module online: the Hub must
    serve each one at the locked version with the locked pack digest."""
    end = time.monotonic() + 30
    while time.monotonic() < end:
        ui.pump()
        if "Completed:" in ui.text():
            return
        if "Not completed:" in ui.text():
            break
    else:
        ui.wait("Completed:", timeout=0)
    rows = ui.text().splitlines()
    first = next(index for index, row in enumerate(rows) if "Not completed:" in row)
    last = next(index for index, row in enumerate(rows) if "Receipt state:" in row)
    reason = "".join(row[row.index("│") + 2:row.rindex("│") - 1] for row in rows[first + 1:last] if row.count("│") >= 2).rstrip()
    if not packed:
        raise AssertionError(f"Hub installation failed in the source workspace: {reason}")
    locked = {module["name"]: module for module in yaml.safe_load((pack / "wippy.lock").read_text())["modules"]}
    causes = []
    for module, version in re.findall(r"(bee/[a-z0-9-]+)@([0-9A-Za-z.+*-]+): module not found", reason):
        causes.append(f"{module}@{version} is not on the Hub")
    for module, version in re.findall(r"manifest digest mismatch for (bee/[a-z0-9-]+)@([0-9A-Za-z.+-]+)", reason):
        causes.append(f"{module}@{version} on the Hub is not the pack this deployment locks ({locked.get(module, {}).get('hash')})")
    raise AssertionError(
        "Hub installation into the packed deployment needs every locked bee/* module on the Hub at its locked "
        "version and digest (make hub-publish publishes them; a pack built from this checkout never carries a "
        f"published digest). {'; '.join(causes) or 'Runtime reason follows.'}\nReason: {reason}")


def exercise_real_facade(project, packed, pack):
    """Use the production Modules -> Hub facade -> service path.

    The public package is read from Hub, while its dependency root and receipt
    are written only to Desktop's disposable local registry. Opening a plan or
    its confirmation screen must leave local inventory unchanged.
    """
    # Bee's own physical modules are installed packages of the launched
    # composition; a deployment also pins its bee/bee root.
    baseline = yaml.safe_load(((pack if packed else project) / "wippy.lock").read_text())["modules"]
    with tempfile.TemporaryDirectory(prefix="bee-modules-real-hub-") as directory:
        ui = Desktop(directory, packed=packed, project=project, deployment=pack,
                     apps=("bee.modules:app",))
        try:
            def click(label):
                for y, line in enumerate(ui.screen.display, 1):
                    if label in line:
                        x = line.index(label) + 1
                        ui.mouse(0, x, y)
                        ui.mouse(0, x, y, True)
                        return
                raise AssertionError(f"Missing click target {label!r}\n{ui.text()}")

            def search_test():
                ui.key(b"/")
                ui.wait("Search packages")
                ui.key(b"\x7f" * 32)
                ui.key(b"test")
                ui.wait("test")
                ui.key(b"\r")
                ui.wait("Search: test")
                ui.wait("Test Framework", timeout=30)

            ui.wait("MODULES", timeout=20)
            ui.wait("Keyword: bee")
            ui.key(b"K")
            ui.wait("Filter by keyword")
            ui.key(b"\x7f\x7f\x7f\r")
            ui.wait("Keyword: all")
            search_test()
            # The catalog row, not the header that names the current selection.
            click("wippy/test  ·")
            ui.wait("Test Framework")
            ui.key(b"v")
            ui.wait("0.4.17", timeout=30)
            click("0.4.17")
            ui.key(b"i")
            ui.key(b"p")
            ui.wait("Ready for confirmation", timeout=30)
            ui.wait("install  wippy/test  0.4.17")
            assert "Completed:" not in ui.text(), "planning published the local dependency root"

            # Review is a presentation step. Confirm opens a second screen;
            # querying the real installed inventory still shows no local root.
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            assert "Completed:" not in ui.text(), "review applied the local dependency root"
            click("Installed")
            ui.wait(f"Your installed packages · {len(baseline)}", timeout=20)

            # Return through the real catalog, prepare a fresh measured plan,
            # and explicitly confirm it. This publishes only to the isolated
            # local registry; no Hive replica or destination activation path is
            # called by the Modules facade.
            click("Catalog")
            ui.wait("MODULES  CATALOG")
            search_test()
            # The catalog row, not the header that names the current selection.
            click("wippy/test  ·")
            ui.wait("Test Framework")
            ui.key(b"v")
            ui.wait("0.4.17", timeout=30)
            click("0.4.17")
            ui.key(b"i")
            ui.key(b"p")
            ui.wait("Ready for confirmation", timeout=30)
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            ui.key(b"\r")
            install_receipt(ui, packed, pack)
            ui.wait("Receipt state: complete")
            click("Installed")
            ui.wait("MODULES  INSTALLED", timeout=20)
            # wippy/test sorts after Bee's own modules and its dependency;
            # select down to its row before reading the installed version.
            ui.key(b"\x1b[B" * (len(baseline) + 2))
            ui.wait("wippy/test", timeout=20)
            ui.wait("0.4.17")
            # Authored publication is separate from a selected Hub installation.
            # This host has no matching authoring profile, so Governance must
            # refuse the explicit prepare request instead of inferring a source.
            click("Authored")
            ui.wait("MODULES  AUTHORING")
            ui.key(b"c")
            ui.wait("Authored overlay version")
            ui.key(b"bee/example\r")
            ui.key(b"v")
            ui.key(b"1.0.0\r")
            ui.key(b"s")
            ui.key(b"a" * 64 + b"\r")
            ui.key(b"p")
            ui.wait("BLOCKED: host has no publication profile", timeout=20)
            ui.quit()
        except Exception:
            Path("/tmp/bee-modules-real-hub-failure.raw").write_bytes(ui.raw)
            raise
        finally:
            ui.close()


def exercise_authored_publication(project, packed, pack):
    """Prove Modules sends explicit prepare then publish requests through Governance."""
    with tempfile.TemporaryDirectory(prefix="bee-modules-authored-") as directory:
        ui = Desktop(directory, packed=packed, project=project, deployment=pack,
                     apps=("bee.modules:app",))
        try:
            ui.wait("MODULES", timeout=20)
            ui.key(b"a")
            ui.wait("MODULES  AUTHORING")
            ui.wait("Freeze the actor-owned overlay")
            ui.key(b"c")
            ui.key(b"acme/authored\r")
            ui.key(b"v")
            ui.key(b"2.4.0\r")
            ui.key(b"s")
            ui.key(b"a" * 64 + b"\r")
            ui.key(b"u")
            ui.wait("prepare this authored version first")
            ui.key(b"p")
            ui.wait("Prepared locally acme/authored 2.4.0", timeout=20)
            ui.wait("Overlays: Stage")
            ui.wait("Return here to publish only")
            ui.key(b"u")
            ui.wait("Published acme/authored 2.4.0", timeout=20)
            ui.quit()
        except Exception:
            Path("/tmp/bee-modules-authored-failure.raw").write_bytes(ui.raw)
            raise
        finally:
            ui.close()


PUBLICATION_METHOD = r'''
local prepared: {[string]: unknown}? = nil
local function handle(raw: unknown): {[string]: unknown}
    assert(type(raw) == "table", "publication request must be an object")
    local request = raw :: {[string]: unknown}
    assert(type(request.workspace_id) == "string" and #request.workspace_id == 32, "Modules must use its admitted workspace")
    assert(request.component == "acme/authored" and request.version == "2.4.0", "authored identity must be explicit")
    if request.operation == "prepare" then
        assert(request.snapshot_digest == string.rep("a", 64), "prepare must include the explicit frozen snapshot digest")
        prepared = {workspace_id = request.workspace_id, component = request.component, version = request.version}
        return {ok = true, replayed = false, value = {component = request.component, version = request.version,
            descriptor = {digest = string.rep("c", 64)}}}
    elseif request.operation == "publish" then
        assert(request.snapshot_digest == nil, "publish must use the reviewed applied version, not caller content")
        assert(prepared ~= nil and prepared.workspace_id == request.workspace_id
            and prepared.component == request.component and prepared.version == request.version,
            "publish must follow preparation of the same authored version")
        return {ok = true, replayed = false, value = {component = request.component, version = request.version}}
    end
    error("unsupported Governance publication operation")
end
return {handle = handle}
'''


def main():
    with fixture_workspace(unit_tests=False) as project:
        (project / "modules/hub/src/binding/facade.lua").write_text(FACADE)
        pack = project / "modules-deployment"
        pack_fixture(project, pack)
        exercise(project, False, pack)
        exercise(project, True, pack)
    with fixture_workspace(unit_tests=False) as project:
        # The test workspace adds wippy/test as a local source dependency for
        # unrelated fixture apps. Remove that root so this scenario proves the
        # Modules flow fetches the public Hub artifact and installs it only on
        # explicit local confirmation.
        found, _ = registry_entries(project, {"test_dependency"})
        index, _ = found["test_dependency"]
        document = yaml.safe_load(index.read_text())
        document["entries"] = [entry for entry in document["entries"]
                              if entry.get("name") != "test_dependency"]
        index.write_text(yaml.safe_dump(document, sort_keys=False))
        # The shared fixture lock carries the test framework and its terminal
        # helper for unrelated app checks. Leaving those modules deployed here
        # makes the real Hub package look like it is replacing host-owned
        # modules when its wildcard terminal dependency resolves. Keep this
        # composition host-free for that package closure so the live resolver
        # exercises the install path rather than a stale test deployment.
        lock = yaml.safe_load((project / "wippy.lock").read_text())
        lock["modules"] = [module for module in lock.get("modules", [])
                            if module.get("name") not in {"wippy/test", "wippy/terminal"}]
        (project / "wippy.lock").write_text(yaml.safe_dump(lock, sort_keys=False))
        pack = project / "modules-real-hub-deployment"
        pack_fixture(project, pack)
        exercise_real_facade(project, False, pack)
        exercise_real_facade(project, True, pack)
    with fixture_workspace(unit_tests=False) as project:
        (project / "modules/hub/src/binding/facade.lua").write_text(FACADE)
        (project / "modules/gov/src/binding/publication_method.lua").write_text(PUBLICATION_METHOD)
        pack = project / "modules-authored-deployment"
        pack_fixture(project, pack)
        exercise_authored_publication(project, False, pack)
        exercise_authored_publication(project, True, pack)
    print("Modules source/pack: Hub install is separate from explicit authored-version preparation; unprofiled preparation is refused")


if __name__ == "__main__":
    main()
