"""Persisted tab presentation through the real Settings application."""
import tempfile
from tui_smoke import Desktop


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-taskbar-") as directory:
        ui = Desktop(directory, packed, apps=("bee.settings:app",))
        try:
            ui.wait("BEE SETTINGS")
            ui.key(b"\t\t")
            ui.wait("Tabs: Labels")
            ui.key(b"\x1b[F")
            ui.wait("Tabs: Icons")
            ui.pump(.3)
            assert "Settings" not in ui.screen.display[0], ui.text()
            assert " S " in ui.screen.display[0], ui.text()
            ui.window_control("−")
            ui.pump(.2)
            x = ui.screen.display[0].index("S") + 1
            ui.mouse(0, x, 1)
            ui.mouse(0, x, 1, True)
            ui.wait("BEE SETTINGS")
            ui.key(b"\x1b[24~")
            ui.wait("Tabs: Icons")
            assert "Settings" not in ui.screen.display[0], ui.text()
            ui.quit()
            ui.close()
            ui = Desktop(directory, packed)
            ui.wait("Tabs: Icons")
            assert "Settings" not in ui.screen.display[0], ui.text()
            ui.key(b"\x1b[H")
            ui.wait("Tabs: Labels")
            ui.pump(.3)
            assert "Settings" in ui.screen.display[0], ui.text()
            ui.quit()
        finally:
            ui.close()
    print(f'Taskbar {"pack" if packed else "source"}: Settings mode, admitted icon, minimize/click restore, F12, cold restore, labels')


if __name__ == "__main__":
    for packed in (False, True):
        exercise(packed)
