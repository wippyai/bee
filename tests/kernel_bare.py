"""A bare-kernel composition boots without the six management-app packages.

The default bundle installs Hive Manager, Timeline, Workspaces, Process
Manager, Modules and Overlays. Removing their dependencies leaves Settings,
Console and Inbox on the kernel: the composition boots, the removed apps are
absent from Start, and only the retained entries remain.
"""
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, strip_dependencies  # noqa: E402

REMOVED = ("Hive Manager", "Timeline", "Workspaces", "Process Manager", "Modules", "Overlays")


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
        state = folder / "state"
        state.mkdir()
        ui = Desktop(str(state), project=project, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS", timeout=90)
            ui.open_start()
            top = ui.text()
            # Terminal is a top-level entry; Settings and Approvals live under
            # Tools, where the six removed management apps used to appear.
            assert "Terminal" in top, top
            ui.choose("Tools")
            ui.pump(1.0)
            tools = ui.text()
            for label in REMOVED:
                assert label not in top and label not in tools, (label, top, tools)
            assert "Approvals" in tools, tools
            assert "Settings" in tools, tools
            ui.quit()
        finally:
            ui.close()
    print("Bare kernel: the six management-app packages are absent, the composition boots, "
          "and Terminal, Approvals and Settings remain", flush=True)


if __name__ == "__main__":
    run()
