"""Physical standalone desktop fixture with disposable stores."""
import codecs
import fcntl
import os
import pty
import struct
import subprocess
import termios
import pyte
from tui_smoke import Desktop

STORE_NAMES = ("workspace", "threads", "approvals", "resources", "credentials", "placement", "gateway", "node", "governance", "sync")
STATE_ENVIRONMENT = {f"BEE_{name.upper()}_DB" for name in STORE_NAMES} | {"BEE_PLACEMENT_ROOT", "BEE_CLIENT_DB"}


class NativeDesktop(Desktop):
    def __init__(self, binary, folder, state, application=None, arguments=(), home=None):
        self.master, slave = pty.openpty()
        self.width, self.height = 100, 30
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.screen = pyte.Screen(100, 30)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = bytearray()
        self.pending_output = ""
        args = [str(binary)]
        if state is not None:
            args.extend(["--state", str(state)])
        if application:
            args.extend(["run", application])
        args.extend(arguments)
        # Exercise the embedded defaults without borrowing the caller's stores.
        # Runtime intentionally permits explicit environment overrides.
        env = {key: value for key, value in os.environ.items()
               if key not in STATE_ENVIRONMENT | {"BEE_RUNTIME", "USER"}}
        env.update(TERM="xterm-256color", HOME=str(home or folder), PATH=f"{folder}/bin:/usr/bin:/bin")
        env["XDG_CONFIG_HOME"] = str((home or folder) / ".config")
        self.process = subprocess.Popen(args, cwd=folder, stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True, env=env)
        os.close(slave)
