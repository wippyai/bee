"""Fresh-pack local desktop acceptance: this checkout's source-free deployment
on the pinned runtime, as a user would launch it while the global bee is
stale. The exact quoted launch command boots; the Start menu carries the
current applications and no Test Status; Terminal takes input and survives a
resize and F12; the desktop exits cleanly; a Settings theme persists across a
relaunch. Runs `run` in the deployment (no `wippy lint`), so the supervisor
lane's pinned lint failure does not block it."""
import codecs
import fcntl
import os
import pty
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path
import pyte
from tui_smoke import Desktop
from workspace import RUNTIME, database_environment, deployment_copy, product_deployment

LAUNCH = [str(RUNTIME), "run", "bee"]


class Literal(Desktop):
    """The quoted launch command, verbatim, in a disposable copy of the deployment."""
    def __init__(self, directory):
        deployment_copy(product_deployment(), directory)
        self.master, slave = pty.openpty()
        self.width, self.height = 100, 30
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.screen = pyte.Screen(100, 30)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = bytearray()
        self.pending_output = ""
        self.first_frame = None
        self.process = subprocess.Popen(LAUNCH, cwd=directory, stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True, env=database_environment(directory, TERM="xterm-256color"))
        os.close(slave)


def literal_boot():
    with tempfile.TemporaryDirectory(prefix="bee-fresh-literal-") as directory:
        ui = Literal(directory)
        try:
            ui.wait("No applications open", timeout=30)
            ui.wait("╰──╲ ╱──╯", timeout=10)
            assert "Test Status" not in ui.text()
            elapsed = ui.quit()
        finally:
            ui.close()
    return elapsed


def desktop(directory, **kwargs):
    return Desktop(directory, packed=True, **kwargs)


def menu_and_terminal(directory):
    ui = desktop(directory)
    try:
        ui.wait("No applications open", timeout=30)
        ui.open_start()
        ui.choose("Tools")
        ui.wait("Approvals", timeout=10)
        text = ui.text()
        for title in ("Approvals", "Timeline", "Hive Manager", "Process Manager", "Settings"):
            assert title in text, (title, text)
        assert "Test Status" not in text, text
        ui.key(b"\x1b")
        ui.key(b"\x1b")
        ui.open_start()
        ui.choose("Terminal")
        ui.wait("$ ", timeout=10)
        ui.key(b"echo fresh-pack-ok\r")
        ui.wait("fresh-pack-ok", timeout=10)
        ui.resize(120, 40)
        assert ui.process.poll() is None
        ui.key(b"echo resized-$COLUMNS\r")
        ui.wait("resized-", timeout=10)
        ui.resize(100, 30)
        assert ui.process.poll() is None
        ui.key(b"\x1b[24~")  # F12 reloads the presenter; the terminal keeps running.
        ui.wait("Terminal", timeout=10)
        ui.key(b"echo after-f12\r")
        ui.wait("after-f12", timeout=10)
        elapsed = ui.quit(confirm=True)
    finally:
        ui.close()
    return elapsed


def settings_persist(directory):
    ui = desktop(directory)
    try:
        ui.wait("No applications open", timeout=30)
        ui.open_start()
        ui.choose("Settings")
        ui.wait("BEE SETTINGS", timeout=10)
        ui.key(b"\x1b[H")
        ui.wait("Theme: Honey")
        ui.key(b"\x1b[C")
        ui.wait("Theme: Ocean")
        ui.quit()
    finally:
        ui.close()
    ui = desktop(directory)
    try:
        ui.wait("BEE SETTINGS", timeout=30)  # the Settings window is recovered on relaunch
        ui.wait("Theme: Ocean", timeout=10)
        ui.window_control("×")
        ui.wait("No applications open", timeout=10)
        ui.quit()
    finally:
        ui.close()


def main():
    literal = literal_boot()
    with tempfile.TemporaryDirectory(prefix="bee-fresh-pack-") as directory:
        session = menu_and_terminal(directory)
    with tempfile.TemporaryDirectory(prefix="bee-fresh-settings-") as directory:
        settings_persist(directory)
    print(f"Fresh pack: literal launch boots (exit {literal:.3f}s); Start menu has Approvals, Timeline, Hive Manager, Process Manager, Settings and no Test Status; "
          f"Terminal input, resize and F12; clean exit {session:.3f}s; Settings theme persists across relaunch")


if __name__ == "__main__":
    main()
