"""The bare kernel boots without installable feature package namespaces."""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop, RUNTIME  # noqa: E402
from workspace import ROOT, database_environment, strip_dependencies  # noqa: E402

REMOVED = ("Hive Manager", "Timeline", "Workspaces", "Process Manager", "Modules", "Overlays")
ALLOWED_NAMESPACES = {
    "bee", "bee.deps", "bee.env", "bee.launch", "bee.desktop", "bee.terminal",
    "bee.client", "bee.session", "bee.host", "bee.apps", "bee.storage",
    "bee.protocol", "bee.interaction", "bee.settings", "bee.console", "bee.persist",
}
ALLOWED_NAMESPACE_TREES = (
    "bee.security", "bee.workspace", "bee.approvals", "bee.threads", "bee.hive",
    "bee.gov", "bee.hub", "bee.gateway", "bee.sync", "bee.node", "bee.application",
    "bee.docs",
)
EXCLUDED_NAMESPACE_TREES = (
    "bee.hive.manager", "bee.threads.timeline", "bee.workspace.manager",
    "bee.host.processes", "bee.hub.modules", "bee.gov.overlays", "bee.agents",
    "bee.harness", "bee.credentials", "bee.driver", "bee.placement", "bee.resources",
    "bee.harness.security", "bee.credentials.security", "bee.placement.native.security",
    "bee.resources.security",
)
EXPECTED_START_ROOT = ["Open application", "Terminal", "Tools", "Exit"]
EXPECTED_START_TOOLS = ["‹ Back", "Approvals", "Settings"]


def _kernel_namespaces(project):
    """Resolve the locked module closure, then inspect production sources."""
    dependency_index = yaml.safe_load((project / "src/deps/_index.yaml").read_text())
    dependencies = {
        entry["component"] for entry in dependency_index.get("entries", [])
        if entry.get("kind") == "ns.dependency"
    }
    lock = yaml.safe_load((project / "wippy.lock").read_text())
    locked = {module["name"] for module in lock.get("modules", [])}
    closure = set()
    pending = list(dependencies)
    while pending:
        component = pending.pop()
        if component in closure:
            continue
        organization, module_name = component.split("/", 1)
        assert organization == "bee", f"Unexpected kernel dependency component: {component}"
        module_source = project / "modules" / module_name / "src"
        assert module_source.is_dir(), f"Locked kernel dependency has no source tree: {component}"
        closure.add(component)
        for index in module_source.rglob("_index.yaml"):
            document = yaml.safe_load(index.read_text()) or {}
            pending.extend(
                entry["component"] for entry in document.get("entries", [])
                if entry.get("kind") == "ns.dependency"
            )
    assert dependencies <= locked and closure == locked, (
        "Bare-kernel dependency closure and lock disagree: "
        f"deps-only={sorted(dependencies - locked)}, "
        f"unlocked={sorted(closure - locked)}, unused={sorted(locked - closure)}"
    )

    sources = {}

    def collect(source_root, *, exclude_test_sources=False):
        for index in source_root.rglob("_index.yaml"):
            relative = index.relative_to(source_root)
            if exclude_test_sources and relative.parts[0] in {"fixtures", "tests"}:
                continue
            document = yaml.safe_load(index.read_text()) or {}
            namespace = document.get("namespace")
            assert isinstance(namespace, str) and namespace, f"Missing namespace in {index}"
            sources.setdefault(namespace, []).append(index.relative_to(project).as_posix())

    collect(project / "src", exclude_test_sources=True)
    for component in sorted(locked):
        module_name = component.split("/", 1)[1]
        collect(project / "modules" / module_name / "src")

    duplicates = {namespace: paths for namespace, paths in sources.items() if len(paths) > 1}
    assert not duplicates, f"Duplicate namespaces in the bare-kernel sources: {duplicates}"
    return sources


def _is_allowed_namespace(namespace):
    if any(namespace == tree or namespace.startswith(tree + ".") for tree in EXCLUDED_NAMESPACE_TREES):
        return False
    return namespace in ALLOWED_NAMESPACES or any(
        namespace == tree or namespace.startswith(tree + ".") for tree in ALLOWED_NAMESPACE_TREES
    )


def _start_items(ui):
    """Read labels in the left Start panel, excluding the desktop behind it."""
    display = ui.screen.display
    top = next((line for line in display if line.startswith("╭") and "╮" in line), None)
    assert top is not None, ui.text()
    right = top.index("╮")
    items = []
    for line in display:
        if len(line) > right and line.startswith("│") and line[right] == "│":
            label = line[1:right].strip()
            if label:
                label = re.sub(r"\s+(?:Ctrl\+[A-Z]|›)$", "", label).strip()
                items.append(label)
        if len(line) > right and line.startswith("╰") and line[right] == "╯":
            break
    return items


def run():
    with tempfile.TemporaryDirectory(prefix="bee-kernel-bare-") as temporary:
        folder = Path(temporary)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        (project / "src/tests").mkdir()
        shutil.copytree(ROOT / "tests/fixtures/desktop_apps", project / "src/fixtures")
        shutil.copytree(ROOT / "tests/fixtures/drivers", project / "fixtures/drivers")
        shutil.copytree(ROOT / "tests/fixtures/harness", project / "fixtures/harness")
        for name in (".wippy.yaml", "wippy.lock", "wippy.yaml"):
            shutil.copy2(ROOT / name, project / name)
        strip_dependencies(project)

        namespaces = _kernel_namespaces(project)
        unexpected = sorted(namespace for namespace in namespaces if not _is_allowed_namespace(namespace))
        assert not unexpected, "Namespaces outside the allowed kernel set:\n" + "\n".join(unexpected)

        cli_state = folder / "cli-state"
        cli_state.mkdir()
        result = subprocess.run([str(RUNTIME), "run", "bee", "claude"], cwd=project,
                                capture_output=True, text=True, timeout=20,
                                env=database_environment(cli_state))
        assert result.returncode != 0 and "Unknown Bee command: claude (install bee/agents)" in (
            result.stdout + result.stderr
        ), (result.returncode, result.stdout, result.stderr)

        state = folder / "state"
        state.mkdir()
        ui = Desktop(str(state), project=project, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS", timeout=90)
            ui.open_start()
            top = ui.text()
            root_items = _start_items(ui)
            assert "Terminal" in top, top
            assert root_items == EXPECTED_START_ROOT, (root_items, top)
            ui.choose("Tools")
            ui.pump(1.0)
            tools = ui.text()
            tool_items = _start_items(ui)
            for label in REMOVED:
                assert label not in top and label not in tools, (label, top, tools)
            assert tool_items == EXPECTED_START_TOOLS, (tool_items, tools)
            assert "Approvals" in tools and "Settings" in tools, tools
            ui.quit()
        finally:
            ui.close()
    print("Bare kernel: only allowed kernel namespaces and kernel apps are present", flush=True)


if __name__ == "__main__":
    run()
