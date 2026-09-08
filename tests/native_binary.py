"""Standalone Bee acceptance: no source or Wippy executable in the launch folder."""
import codecs
import fcntl
import os
from pathlib import Path
import pty
import struct
import subprocess
import sys
import tempfile
import termios

import pyte
from tui_smoke import Desktop

BINARY = Path(sys.argv[1]).resolve()


class NativeDesktop(Desktop):
    def __init__(self, folder, state, application=None):
        self.master, slave = pty.openpty()
        self.width, self.height = 100, 30
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.screen = pyte.Screen(100, 30)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = bytearray()
        self.pending_output = ""
        args = [str(BINARY), "--state-dir", str(state)]
        if application:
            args.extend(["--command", "bee-app", "run", application])
        env = {key: value for key, value in os.environ.items() if key not in ("BEE_WORKSPACE_DB", "BEE_THREADS_DB", "BEE_RUNTIME")}
        env.update(TERM="xterm-256color", HOME=str(folder), PATH="/usr/bin:/bin")
        self.process = subprocess.Popen(args, cwd=folder, stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True, env=env)
        os.close(slave)


with tempfile.TemporaryDirectory(prefix="bee-native-binary-") as temporary:
    folder = Path(temporary) / "empty launch folder"
    folder.mkdir()
    state = Path(temporary) / "bee state"
    ui = NativeDesktop(folder, state, "bee.settings:app")
    try:
        ui.wait("Settings")
        ui.key(b"\x1b[24~")
        ui.wait("Settings")
        ui.quit()
    finally:
        ui.close()
    assert (state / "workspace.db").is_file(), "Workspace data did not use the selected native state directory"
    assert (state / "deployment/wippy.lock").is_file(), "No canonical application deployment"
    ui = NativeDesktop(folder, state)
    try:
        ui.wait("Settings")
        ui.quit()
    finally:
        ui.close()
    ui = NativeDesktop(folder, state, "bee.console:app")
    try:
        ui.wait("Terminal")
        ui.key(b"printf '\\102\\105\\105\\137\\116\\101\\124\\111\\126\\105\\137\\117\\113\\n'\r")
        ui.wait("BEE_NATIVE_OK")
        ui.key(b"\x1b[24~")
        ui.wait("BEE_NATIVE_OK")
        ui.quit(confirm=True)
    finally:
        ui.close()
    assert not (folder / ".wippy").exists(), "Native host wrote runtime state into the caller directory"
print("Standalone Bee: embedded boot, Settings recovery, native terminal and presenter rejoin passed")
