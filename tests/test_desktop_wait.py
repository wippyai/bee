"""Desktop startup waits for its frame even when scheduling takes over four seconds."""
from types import SimpleNamespace
from unittest.mock import patch
import unittest

from tui_smoke import DESKTOP_HANG_SECONDS, Desktop


class DesktopWaitTest(unittest.TestCase):
    def test_settings_frame_after_four_seconds(self):
        clock = [0]
        def pump():
            clock[0] += 1
        desktop = SimpleNamespace(
            pump=pump,
            text=lambda: "BEE SETTINGS" if clock[0] >= 5 else "Starting",
            process=SimpleNamespace(pid=1, poll=lambda: None),
        )
        with patch("tui_smoke.time.monotonic", side_effect=lambda: clock[0]):
            Desktop.wait(desktop, "BEE SETTINGS")
        self.assertEqual(clock[0], 5)

    def test_missing_frame_still_has_hang_guard(self):
        clock = [0]
        desktop = SimpleNamespace(
            pump=lambda: clock.__setitem__(0, clock[0] + DESKTOP_HANG_SECONDS + 1),
            text=lambda: "Starting",
            process=SimpleNamespace(pid=1, poll=lambda: None),
            master=None,
            raw=bytearray(),
            pending_output="",
        )
        with patch("tui_smoke.time.monotonic", side_effect=lambda: clock[0]), \
                patch("tui_smoke.lookup", return_value=None):
            with self.assertRaisesRegex(AssertionError, "Missing 'BEE SETTINGS'"):
                Desktop.wait(desktop, "BEE SETTINGS")


if __name__ == "__main__":
    unittest.main()
