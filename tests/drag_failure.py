"""Inject one failed placement send; ensure pointer capture is released."""
import tempfile

from tui_smoke import Desktop
from workspace import fixture_workspace

with fixture_workspace(unit_tests=False) as project:
    presenter = project / "src/terminal/main.lua"
    source = presenter.read_text()
    start = 'local sent, send_error = process.send(owner, "bee.desktop.command", {version = 1, op = "place", id = capture.id,'
    end = 'x = preview.x, y = preview.y, width = preview.width, height = preview.height})'
    old = start + "\n                                    " + end
    assert source.count(old) == 1
    # Only this actor's final drag send fails. Focus, menus and app routing stay real.
    presenter.write_text(source.replace(old, 'local sent, send_error = false, "Injected placement failure"'))
    with tempfile.TemporaryDirectory(prefix="bee-drag-failure-") as directory:
        ui = Desktop(directory, project=project)
        try:
            ui.wait("No applications open")
            ui.open_start()
            ui.choose("Settings")
            ui.wait("BEE SETTINGS")
            def outline():
                y, line = next((y, line) for y, line in enumerate(ui.screen.display, 1) if "╭─ Settings" in line)
                x = line.index("╭")
                bottom = next(row for row, text in enumerate(ui.screen.display, 1) if text[x:x + 1] == "╰")
                return x + 1, y, line.rindex("╮") + 1, bottom
            before = outline()
            ui.mouse(0, before[0] + 5, before[1])
            ui.mouse(32, before[0] + 9, before[1] + 1)
            ui.mouse(0, before[0] + 9, before[1] + 1, True)
            assert outline() == before, "Failed placement retained preview geometry"
            ui.open_start()
            ui.choose("Process Manager")
            ui.wait("Heap")
            ui.quit()
        finally:
            ui.close()
print("Placement send failure releases capture; subsequent pointer navigation works")
