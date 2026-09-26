"""A retained window of an uninstalled package drops cleanly.

Open a management app that checkpoints itself, save the composition, then boot
the same workspace without that package. The missing definition must admit
nothing: the app never restores or appears in Start, and its retained window
leaves the saved layout, while the composition still boots instead of failing
on the uninstalled package admission record.
"""
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, classic_workspace, client_layout, strip_dependencies, workspace_checkpoint  # noqa: E402

PACKAGE = "bee/threads-timeline"
DEFINITION = "bee.threads.timeline:app"


def run():
    with tempfile.TemporaryDirectory(prefix="bee-kernel-drop-") as temporary:
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
        state = folder / "state"
        state.mkdir()
        database = state / "workspace.db"
        client_database = state / "workspace.db.client"
        ui = Desktop(str(state), project=project, apps=(DEFINITION,))
        try:
            ui.wait("TIMELINE", timeout=90)
            ui.quit()
        finally:
            ui.close()
        workspace_id = classic_workspace(database)
        before = workspace_checkpoint(database)
        assert [record["definition_id"] for record in before["applications"]] == [DEFINITION], before
        view_id = before["applications"][0]["id"]
        before_layout = client_layout(client_database, workspace_id)[1]
        assert [target["view_id"] for target in before_layout["targets"]] == [view_id], before_layout
        assert len(before_layout["scene"]["windows"]) == 1, before_layout

        # Remove the package and boot the same state again.
        strip_dependencies(project, (PACKAGE,))
        ui = Desktop(str(state), project=project, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS", timeout=90)
            ui.pump(1.0)
            text = ui.text()
            assert "TIMELINE" not in text, text
            assert "Timeline" not in text, text
            ui.quit()
        finally:
            ui.close()

        # The window left the layout; its manual checkpoint stays retained
        # without restoring, and no duplicate instance was created.
        layout = client_layout(client_database, workspace_id)[1]
        assert view_id not in [target["view_id"] for target in layout["targets"]], layout
        assert not [window for window in layout["scene"]["windows"] if window["id"] == view_id], layout
        after = workspace_checkpoint(database)
        records = [record for record in after["applications"] if record["definition_id"] == DEFINITION]
        assert len(records) == 1 and records[0]["id"] == view_id and records[0]["restart_policy"] == "manual", after
    print("Uninstalled package: the retained window dropped through the missing-definition path, "
          "the app did not restore, and the composition booted", flush=True)


if __name__ == "__main__":
    run()
