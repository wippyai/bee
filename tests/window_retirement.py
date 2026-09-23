"""A view failure must retire with its window, even without a close reply."""
from pathlib import Path
import tempfile
import time
from tui_smoke import Desktop
from workspace import fixture_workspace, pack_fixture


def exercise(packed):
    with fixture_workspace(unit_tests=False) as project, tempfile.TemporaryDirectory(prefix="bee-window-retirement-") as directory:
        delivery = project / "src/core/terminal/delivery.lua"
        source = delivery.read_text()
        source = source.replace("local M = {}", 'local first_view = ""\nlocal fail_first = false\nlocal M = {}', 1)
        anchor = 'function M.attach(id: string, mount: string, observer: boolean?): (boolean, string?)\n'
        assert source.count(anchor) == 1
        source = source.replace(anchor, anchor + '    if first_view == "" then first_view = id elseif first_view ~= id then fail_first = true end\n', 1)
        anchor = 'function M.content(id: string, width: integer, height: integer): (Content?, string?)\n'
        assert source.count(anchor) == 1
        source = source.replace(anchor, anchor + '    if id == first_view and fail_first then return nil, "Injected view failure" end\n', 1)
        delivery.write_text(source)
        # A host inventory can remove a window independently of a close reply.
        presenter = project / "src/core/terminal/main.lua"
        source = presenter.read_text()
        anchor = 'if reply and decode.belongs(reply, workspace_id) then'
        assert source.count(anchor) == 1
        presenter.write_text(source.replace(anchor, 'if reply and reply.op ~= "closed" and reply.op ~= "close" and decode.belongs(reply, workspace_id) then', 1))
        pack = project / "deployment"
        if packed:
            pack_fixture(project, pack)
        ui = Desktop(directory, packed=packed, project=project, deployment=pack)
        try:
            ui.wait("No applications open")
            ui.open_start(); ui.choose("Settings"); ui.wait("BEE SETTINGS")
            ui.open_start(); ui.choose("Tools"); ui.choose("Process Manager"); ui.wait("Heap")
            ui.wait("Injected view failure")
            x = ui.screen.display[0].index("Settings") + 2
            ui.mouse(2, x, 1); ui.mouse(2, x, 1, True)
            ui.choose("Close")
            deadline = time.monotonic() + 2
            while "Settings" in ui.screen.display[0] and time.monotonic() < deadline:
                ui.pump(.05)
            assert "Settings" not in ui.screen.display[0], ui.text()
            assert "Injected view failure" not in ui.text(), ui.text()
            ui.quit()
        finally:
            ui.close()
    print("Window retirement clears its delivery failure after committed removal", "pack" if packed else "source")


if __name__ == "__main__":
    exercise(False)
    exercise(True)
