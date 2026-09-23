"""Live PTY acceptance for source and portable pack; never uses workspace DBs.

Requires pyte (terminal emulator). A packed launch runs a source-free deployment
copied into its working directory. All processes and state are owned by this
harness and cleaned in finally blocks.
"""
from workspace import database_environment
import codecs
import fcntl
import http.client
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

import pyte
from workspace import deployment_copy, fixture_workspace, pack_fixture, product_deployment

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get("BEE_RUNTIME", ROOT / ".wippy/bin/bee-wippy")).resolve()


class Desktop:
    def __init__(self, directory, packed=False, project=ROOT, deployment=None, apps=(), launcher=False, command_name="bee"):
        self.master, slave = pty.openpty()
        self.width, self.height = 100, 30
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.screen = pyte.Screen(100, 30)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = bytearray()
        self.pending_output = ""
        cwd = directory if packed else project
        if packed:
            deployment_copy(deployment or product_deployment(), directory)
        args = [str(RUNTIME), "run", command_name]
        args += list(apps) + ["--host", "bee:terminal", "--set", f"registry.history_path={directory}/registry.db"]
        if launcher:
            args = [str(ROOT / "run.sh"), "--set", f"registry.history_path={directory}/registry.db"]
            cwd = directory
        self.process = subprocess.Popen(args, cwd=cwd, stdin=slave, stdout=slave, stderr=slave,
                                        start_new_session=True, env=database_environment(directory, TERM="xterm-256color"))
        os.close(slave)

    def pump(self, duration=.1):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            if select.select([self.master], [], [], .02)[0]:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    return
                self.raw.extend(chunk)
                self.pending_output += self.decoder.decode(chunk)
                # pyte does not implement DEC synchronized output. Publish whole
                # frames so assertions never inspect an intermediate OS write.
                begin, end_frame = "\x1b[?2026h", "\x1b[?2026l"
                while self.pending_output:
                    start = self.pending_output.find(begin)
                    if start < 0:
                        safe = max(0, len(self.pending_output) - len(begin) + 1)
                        self.stream.feed(self.pending_output[:safe])
                        self.pending_output = self.pending_output[safe:]
                        break
                    if start:
                        self.stream.feed(self.pending_output[:start])
                        self.pending_output = self.pending_output[start:]
                    finish = self.pending_output.find(end_frame, len(begin))
                    if finish < 0:
                        break
                    self.stream.feed(self.pending_output[len(begin):finish])
                    if hasattr(self, "observed_frames"):
                        self.observed_frames.append(list(self.screen.display))
                    self.pending_output = self.pending_output[finish + len(end_frame):]

    def wait(self, text, timeout=4):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.pump()
            if text in self.text():
                return
            if self.process.poll() is not None:
                break
        try:
            state = next(line for line in Path(f'/proc/{self.process.pid}/status').read_text().splitlines()
                         if line.startswith('State:'))
        except (OSError, StopIteration):
            state = 'unavailable'
        raw_tail = bytes(self.raw[-2048:])
        raise AssertionError(
            f"Missing {text!r}; exit={self.process.poll()}; process_state={state}; "
            f"raw_bytes={len(self.raw)}; raw_tail={raw_tail!r}; "
            f"pending_synchronized_bytes={len(self.pending_output.encode())}\n{self.text()}")

    def text(self):
        return "\n".join(self.screen.display)

    def key(self, value):
        os.write(self.master, value)
        self.pump(.2)

    def resize(self, width, height):
        self.screen.resize(lines=height, columns=width)
        self.width, self.height = width, height
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
        os.kill(self.process.pid, signal.SIGWINCH)
        self.pump(.25)

    def mouse(self, code, x, y, release=False):
        suffix = "m" if release else "M"
        self.key(f"\x1b[<{code};{x};{y}{suffix}".encode())

    def frame(self):
        borders = []
        for y, line in enumerate(self.screen.display, 1):
            left, right = max(line.find("╭"), line.find("╰")), max(line.rfind("╮"), line.rfind("╯"))
            if left >= 0 and right > left:
                borders.append((left + 1, y, right + 1))
        assert len(borders) == 2, self.text()
        return borders[0][0], borders[0][1], borders[0][2], borders[1][1]

    def window_control(self, symbol):
        y, line = next((y, line) for y, line in enumerate(self.screen.display, 1) if "×" in line and symbol in line)
        x = line.index(symbol) + 1
        self.mouse(0, x, y)
        self.mouse(0, x, y, True)

    def settings_frame_colors(self):
        y, title = next((y, line) for y, line in enumerate(self.screen.display) if "Settings" in line and "×" in line)
        left, right = title.index("╭"), title.index("╮")
        bottom = next(row for row in range(y + 1, self.height)
                      if self.screen.display[row][left] == "╰" and self.screen.display[row][right] == "╯")
        surface = self.screen.buffer[y + 1][left + 1].bg
        for x in range(left, right + 1):
            assert self.screen.buffer[y][x].bg == surface, ("top border band", x, self.text())
            assert self.screen.buffer[bottom][x].bg == surface, ("bottom border band", x, self.text())
        for row in range(y, bottom + 1):
            assert self.screen.buffer[row][left].bg == surface
            assert self.screen.buffer[row][right].bg == surface

    def corners(self):
        for edge, dx, dy in [("tl", 2, 1), ("tr", 3, -1), ("br", 3, 2), ("bl", -2, 1)]:
            left, top, right, bottom = self.frame()
            x = left if "l" in edge else right
            y = top if "t" in edge else bottom
            self.mouse(0, x, y)
            self.mouse(32, x + dx, y + dy)
            self.mouse(0, x + dx, y + dy, True)
            got = self.frame()
            expected = (left + (dx if "l" in edge else 0), top + (dy if "t" in edge else 0),
                        right + (dx if "r" in edge else 0), bottom + (dy if "b" in edge else 0))
            assert got == expected, (edge, got, expected, self.text())

    def quit(self, confirm=False):
        start = time.monotonic()
        os.write(self.master, b"\x11")
        if confirm:
            self.wait("Quit Bee?")
            start = time.monotonic()
            os.write(self.master, b"\t\r")
        while self.process.poll() is None and time.monotonic() - start < 2:
            self.pump(.02)
        assert self.process.poll() == 0, self.text()
        elapsed = time.monotonic() - start
        assert elapsed < 1, f"Exit took {elapsed:.3f}s"
        return elapsed

    def rejoin(self, crash=False):
        header = self.screen.display[0]
        body = self.screen.display[1:]
        app_pids = re.findall(r"App PID: (\S+)", self.text())
        assert app_pids and all(pid.endswith("}") for pid in app_pids), "Fixture PID suffix was clipped"
        raw_start = len(self.raw)
        self.key(b"\x1b[21~" if crash else b"\x1b[24~")  # F10 is injected only in the fixture presenter.
        deadline = time.monotonic() + 4
        while self.screen.display[0] == header and time.monotonic() < deadline:
            self.pump(.05)
        assert self.screen.display[0] != header, f"Presenter did not change incarnation; exit={self.process.poll()}\n{self.text()}\n{bytes(self.raw[raw_start:])!r}"
        self.pump(.15)
        assert self.screen.display[1:] == body, (body, self.text())
        assert re.findall(r"App PID: (\S+)", self.text()) == app_pids
        assert b"\x1b[?1049l" not in self.raw[raw_start:], "Rejoin released the physical screen"

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        os.close(self.master)

    def assert_local_only(self):
        """The native MCP listener is loopback-only and grants no anonymous tools."""
        assert self.process.poll() is None
        process_dir = Path(f"/proc/{self.process.pid}")
        sockets = set()
        for descriptor in (process_dir / "fd").iterdir():
            try:
                target = os.readlink(descriptor)
            except FileNotFoundError:
                continue
            if target.startswith("socket:["):
                sockets.add(target[8:-1])
        bound = []
        for protocol in ("tcp", "tcp6", "udp", "udp6"):
            for row in (process_dir / "net" / protocol).read_text().splitlines()[1:]:
                fields = row.split()
                if fields[9] not in sockets:
                    continue
                if fields[3] == "0A" or (protocol.startswith("udp") and fields[1].split(":")[-1] != "0000"):
                    bound.append((protocol, fields[1], fields[3]))
        assert len(bound) == 1, f"Expected one native MCP listener: {bound}"
        protocol, endpoint, state = bound[0]
        address, encoded_port = endpoint.split(":")
        port = int(encoded_port, 16)
        assert protocol == "tcp" and state == "0A" and address == "0100007F", bound
        assert 0 < port <= 65535, bound
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        try:
            connection.request("POST", "/mcp/unauthorized-probe",
                               body='{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}',
                               headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            assert response.status == 401, f"Anonymous MCP request returned {response.status}"
            response.read(65536)
        finally:
            connection.close()
        assert self.process.poll() is None

    def exhausted_recovery(self):
        # One injected crash already recovered. Exhaust the remaining automatic
        # attempts, then prove manual retry retains the original application.
        self.rejoin(crash=True)
        self.rejoin(crash=True)
        app_pids = re.findall(r"App PID: (\S+)", self.text())
        header = self.screen.display[0]
        raw_start = len(self.raw)
        self.key(b"\x1b[21~")
        self.wait("Desktop paused")
        assert self.process.poll() is None
        assert re.findall(r"App PID: (\S+)", self.text()) == app_pids
        self.key(b"\x1b[24~")
        deadline = time.monotonic() + 4
        while "Desktop paused" in self.text() and time.monotonic() < deadline:
            self.pump(.05)
        assert "Desktop paused" not in self.text(), self.text()
        assert self.screen.display[0] != header
        assert re.findall(r"App PID: (\S+)", self.text()) == app_pids
        self.wait("Keys received here: 1")
        assert b"\x1b[?1049l" not in self.raw[raw_start:]

    def open_start(self):
        self.key(b"\x1bOP")
        self.wait("Tools")

    def choose(self, label):
        if label in {"Settings", "Process Manager"} and not any(label in line and "│" in line for line in self.screen.display[1:]):
            self.choose("Tools")
        line = next(i for i, text in enumerate(self.screen.display) if i > 0 and label in text and "│" in text and text.index("│") < text.index(label))
        x = self.screen.display[line].index(label) + 1
        self.mouse(0, x, line + 1)
        self.mouse(0, x, line + 1, True)


def exercise(packed, project, deployment):
    with tempfile.TemporaryDirectory(prefix="bee-acceptance-") as directory:
        ui = Desktop(directory, packed, project=project, deployment=deployment, apps=("bee.apps:welcome", "bee.apps:palette"))
        try:
            ui.wait("Small shell. Independent applications.")
            ui.assert_local_only()
            ui.corners()
            before = ui.frame()
            ui.mouse(0, before[0] + 5, before[1])
            ui.mouse(32, before[0] + 9, before[1] + 1)
            ui.key(b"\x1b")
            ui.mouse(0, before[0] + 9, before[1] + 1, True)
            assert ui.frame() == before, "Escape committed a drag"
            ui.wait("Keys received here: 0")
            # Desktop focus cannot deliver private typing into an application.
            ui.mouse(0, 99, 29)
            ui.mouse(0, 99, 29, True)
            ui.key(b"not app input")
            ui.wait("Keys received here: 0")
            ui.key(b"\x1b\t")
            ui.key(b"a")
            ui.wait("Keys received here: 1")
            ui.open_start()
            ui.key(b"ignored\x1b[200~private paste\x1b[201~")
            ui.key(b"\x1b")
            ui.wait("Keys received here: 1")
            ui.key(b"\x1b[20;3~")  # Alt+F9 minimizes without stealing Enter/Ctrl+M.
            ui.wait("╰──╲ ╱──╯")
            assert "− Welcome" in ui.screen.display[0], ui.text()
            ui.key(b"\x1b\t")  # All minimized: cycling must still restore an app.
            ui.wait("Keys received here: 1")
            before_drop = ui.frame()
            ui.mouse(0, before_drop[0] + 5, before_drop[1])
            ui.mouse(32, before_drop[0] + 9, before_drop[1] + 1)
            preview = ui.frame()
            ui.observed_frames = []
            ui.mouse(0, before_drop[0] + 9, before_drop[1] + 1, True)
            ui.pump(.3)
            assert ui.frame() == preview
            for frame in ui.observed_frames:
                border = [(line.index("╭") + 1, y) for y, line in enumerate(frame, 1) if "╭" in line]
                assert border == [(preview[0], preview[1])], (border, preview, "Drop flashed old position")
            del ui.observed_frames
            original = ui.frame()
            ui.mouse(2, original[0] + 5, original[1])
            ui.mouse(2, original[0] + 5, original[1], True)
            ui.choose("Collapse")
            ui.pump(.1)
            assert "Keys received here" not in ui.text()
            title_y, title = next((y, line) for y, line in enumerate(ui.screen.display, 1) if "Welcome" in line and "×" in line)
            assert "╭" not in title and "╮" not in title, "Collapsed bar is an unfinished frame"
            x = title.index("Welcome") + 1
            ui.mouse(0, x, title_y)
            ui.mouse(32, x + 3, title_y + 1)
            ui.mouse(0, x + 3, title_y + 1, True)
            moved = ui.screen.display[title_y]
            assert moved.index("Welcome") + 1 == x + 3, ui.text()
            restore_x = moved.index("◇") + 1
            ui.mouse(0, restore_x, title_y + 1)
            ui.mouse(0, restore_x, title_y + 1, True)
            ui.wait("Keys received here: 1")
            got = ui.frame()
            assert got == (original[0] + 3, original[1] + 1, original[2] + 3, original[3] + 1), (original, got)
            for _ in range(5):
                ui.rejoin()
            ui.rejoin(crash=True)
            ui.exhausted_recovery()
            ui.key(b"\x0e")
            ui.wait("Keys received here: 0")
            assert ui.screen.display[0].count("Welcome") == 2, ui.text()
            ui.key(b"\x1b[20;3~\x1b[20;3~ignored")
            ui.wait("╰──╲ ╱──╯")
            ui.key(b"\x1b\t")
            ui.wait("Keys received here: 1")
            ui.key(b"\x1b\t")
            ui.wait("Keys received here: 0")
            ui.key(b"\x1b[20;3~M")
            ui.wait("Keys received here: 2")
            ui.key(b"\x1b\t")
            ui.wait("Keys received here: 0")
            # One terminal read: focus intent and app key race the session reply.
            ui.key(b"\x1b\tZ")
            ui.wait("Keys received here: 3")
            ui.key(b"\x1b\t")
            ui.wait("Keys received here: 0")
            # Clicking an already focused tab is a no-op that still needs an ack.
            tab_x = ui.screen.display[0].rindex("Welcome") + 1
            ui.mouse(0, tab_x, 1)
            ui.mouse(0, tab_x, 1, True)
            ui.key(b"\x10")
            ui.wait("Scope isolation checks passed")
            ui.key(b"Q")
            ui.wait("Keys received here: 1")
            ui.key(b"\x1b[23~")
            ui.wait("SURFACE LAB")
            assert "Small shell." not in ui.text(), "A floating app obscured focused fullscreen content"
            # Text and blank cells inherit page background; explicit color survives.
            assert ui.screen.buffer[1][2].bg == "17202c", ui.screen.buffer[1][2]
            assert ui.screen.buffer[20][80].bg == "17202c", ui.screen.buffer[20][80]
            assert any(cell.bg == "244c78" for row in ui.screen.buffer.values() for cell in row.values())
            ui.open_start()
            ui.choose("Settings")
            ui.wait("BEE SETTINGS")
            ui.key(b"\x1b[C")
            ui.wait("Theme: Ocean")
            ui.key(b"\x1b")
            ui.wait("SURFACE LAB")
            assert ui.screen.buffer[20][80].bg == "102b39", ui.screen.buffer[20][80]
            assert any(cell.bg == "244c78" for row in ui.screen.buffer.values() for cell in row.values())
            ui.rejoin()
            ui.open_start()
            ui.choose("Settings")
            ui.wait("Theme: Ocean")
            ui.key(b"\x1b[H")
            ui.wait("Theme: Honey")
            ui.key(b"\x1b")
            ui.wait("SURFACE LAB")
            # App-local Tab is preserved, and clicking an already active tab
            # must not turn a fullscreen application back into a floating one.
            ui.key(b"\t")
            ui.wait("Keys received here: 2")
            ui.rejoin()
            tab_x = ui.screen.display[0].index("Colors") + 1
            ui.mouse(0, tab_x, 1)
            ui.mouse(0, tab_x, 1, True)
            assert "Small shell." not in ui.text(), ui.text()
            # Stable focus cycling must return to Colors without toggling fullscreen.
            for _ in range(3):
                ui.key(b"\x1b\t")
            assert "Small shell." not in ui.text(), ui.text()
            ui.key(b"\x17")
            ui.pump(.2)
            assert "Colors" not in ui.screen.display[0], ui.text()
            for width, height in [(18, 6), (1, 1), (2, 2), (100, 30)]:
                ui.resize(width, height)
                assert ui.process.poll() is None, ui.text()
            ui.key(b"\x1b[23~")
            ui.wait("Small shell. Independent applications.")
            exit_seconds = ui.quit()
            faults = [bytes(ui.raw[max(0, match.start() - 120):match.end() + 300])
                      for match in re.finditer(b"permission denied|stack traceback", ui.raw)]
            assert not faults, faults
            print(f"{'pack' if packed else 'source'}: isolation, input, geometry, colors, six rejoins, crash recovery; exit {exit_seconds:.3f}s")
        finally:
            ui.close()


def core_boot(packed):
    with tempfile.TemporaryDirectory(prefix="bee-empty-core-") as directory:
        ui = Desktop(directory, packed, launcher=not packed)
        try:
            ui.wait("No applications open")
            ui.wait("╰──╲ ╱──╯")
            assert "Starting…".encode() in ui.raw, "Boot frame was never presented"
            ui.mouse(0, 3, 1)
            ui.mouse(0, 3, 1, True)
            ui.wait("Tools")
            assert ui.screen.display[1][0] == "╭" and ui.screen.display[1][34] == "╮"
            ui.choose("Settings")
            ui.wait("BEE SETTINGS")
            ui.settings_frame_colors()
            ui.window_control("−")
            ui.wait("╰──╲ ╱──╯")
            tab_x = ui.screen.display[0].index("Settings") + 1
            ui.mouse(0, tab_x, 1)
            ui.mouse(0, tab_x, 1, True)
            ui.wait("BEE SETTINGS")
            ui.window_control("□")
            assert "BEE SETTINGS" in ui.screen.display[1], ui.text()
            ui.window_control("◇")
            ui.settings_frame_colors()
            ui.key(b"\x1b[6~")
            ui.wait("Ember")
            ui.wait("Theme: Honey")
            pager_y, pager_line = next((y, line) for y, line in enumerate(ui.screen.display, 1) if "/16" in line and "‹" in line)
            back_x = pager_line.index("‹") + 1
            ui.mouse(0, back_x, pager_y)
            ui.mouse(0, back_x, pager_y, True)
            ui.wait("Ocean")
            ui.key(b"\x1b[6~")
            ui.wait("Ember")
            ui.key(b"\x1b[5~")
            ui.wait("Ocean")
            ocean_y, ocean_line = next((y, line) for y, line in enumerate(ui.screen.display, 1) if "Ocean" in line)
            ocean_x = ocean_line.index("Ocean") + 1
            ui.mouse(0, ocean_x, ocean_y)
            ui.mouse(0, ocean_x, ocean_y, True)
            ui.wait("Theme: Ocean")
            ui.key(b"\x1b[H")
            ui.wait("Theme: Honey")
            for theme in ["Ocean", "Forest", "Plum", "Ember", "Graphite", "Paper", "Aurora", "Rose", "Cobalt", "Sand", "Midnight", "Lavender", "Mono", "DOS Blue", "Windows Classic"]:
                ui.key(b"\x1b[C")
                ui.wait("Theme: " + theme)
                ui.settings_frame_colors()
                if theme == "Windows Classic":
                    row, line = next((y, line) for y, line in enumerate(ui.screen.display) if "Themes" in line)
                    cell = ui.screen.buffer[row][line.index("Themes")]
                    assert (cell.fg, cell.bg) == ("ffffff", "000080"), (cell.fg, cell.bg)
            ui.key(b"\x1b[H")
            ui.key(b"\x1b[C")
            ui.wait("Theme: Ocean")
            nav_y, nav_line = next((y, line) for y, line in enumerate(ui.screen.display, 1) if "Backgrounds" in line)
            nav_x = nav_line.index("Backgrounds") + 1
            ui.mouse(0, nav_x, nav_y)
            ui.mouse(0, nav_x, nav_y, True)
            ui.wait("Solid")
            # Browsing cards must not silently select/apply a wallpaper.
            ui.mouse(65, 10, nav_y + 4)
            ui.wait("Background: dots")
            ui.key(b"\x1b[H")
            for background in ["solid", "grid", "horizon", "stars", "weave", "crosshatch", "bricks", "diagonal", "waves", "hex"]:
                ui.key(b"\x1b[C")
                ui.wait("Background: " + background)
            ui.key(b"\x1b[H")
            ui.wait("Background: dots")
            ui.resize(30, 10)
            compact_y, compact = next((y, line) for y, line in enumerate(ui.screen.display, 1) if "‹" in line and "›" in line)
            next_x = compact.rindex("›") + 1
            ui.mouse(0, next_x, compact_y)
            ui.mouse(0, next_x, compact_y, True)
            ui.wait("solid")
            ui.resize(100, 30)
            ui.wait("Background: solid")
            ui.settings_frame_colors()
            ui.key(b"\x1b[H")
            ui.wait("Background: dots")
            ui.key(b"\x1b[24~")
            ui.pump(.2)
            ui.wait("Theme: Ocean")
            ui.wait("Background: dots")
            ui.window_control("×")
            ui.wait("No applications open")
            ui.open_start()
            ui.resize(22, 7)
            ui.key(b"\x1b[F")
            ui.wait("Exit")
            ui.key(b"\x1b")
            ui.resize(1, 1)
            assert ui.process.poll() is None
            ui.resize(100, 30)
            ui.wait("╰──╲ ╱──╯")
            ui.pump(.3)
            assert "Welcome" not in ui.text() and "Colors" not in ui.text(), ui.text()
            assert ui.process.poll() is None, ui.text()
            elapsed = ui.quit()
            print(f"Core {'pack' if packed else 'source'}: empty desktop, no fixture autostart; exit {elapsed:.3f}s")
        finally:
            ui.close()

def process_manager(packed):
    with tempfile.TemporaryDirectory(prefix="bee-monitor-") as directory:
        ui = Desktop(directory, packed, launcher=not packed)
        try:
            ui.wait("No applications open")
            ui.open_start()
            assert "Minimize" not in ui.text() and "Reload desktop" not in ui.text()
            assert "Enter Choose" not in ui.text() and "Applications" not in ui.text()
            ui.choose("Tools")
            line = next(y for y, text in enumerate(ui.screen.display, 1) if "Process Manager" in text)
            ui.mouse(35, 5, line)  # SGR motion with no button: hover only.
            hover_bg = ui.screen.buffer[line - 1][4].bg
            assert hover_bg != ui.screen.buffer[line - 2][4].bg, ui.text()
            assert "Heap" not in ui.text(), "Hover launched an application"
            ui.key(b"\r")
            ui.wait("Heap"); ui.wait("bee.applications:broker")
            ui.pump(1.2)
            assert "permission denied" not in ui.text(), ui.text()
            ui.key(b"p"); ui.wait("Paused")
            paused = ui.screen.display[6:10]
            ui.pump(1.2)
            assert ui.screen.display[6:10] == paused, "Paused chart changed"
            ui.key(b"p"); ui.wait("Live")
            ui.key(b"\x1b[3~\r")
            ui.wait("Core processes are protected")
            ui.key(b"\t"); ui.wait("SERVICE")
            # Service inventory may exceed the viewport; workers sorts last.
            ui.key(b"\x1b[F")
            ui.wait("bee:workers")
            ui.key(b"\t"); ui.wait("bee.applications:broker")
            ui.open_start(); ui.choose("Settings"); ui.wait("BEE SETTINGS")
            ui.open_start(); ui.choose("Process Manager"); ui.wait("Heap")
            # New supervised services can put Settings below the visible rows.
            # Navigate the actual list instead of assuming the entire inventory fits.
            ui.key(b"\x1b[H")
            for _ in range(64):
                if "bee.settings:app" in ui.text():
                    break
                ui.key(b"\x1b[B")
                ui.pump(.05)
            ui.wait("bee.settings:app")
            assert ui.screen.display[0].count("Process Manager") == 1, ui.text()
            row = next(y for y, text in enumerate(ui.screen.display, 1) if "bee.settings:app" in text)
            ui.mouse(0, 5, row); ui.mouse(0, 5, row, True)
            ui.key(b"\x1b[3~"); ui.wait("Stop selected app?")
            ui.key(b"\r"); ui.wait("Application ended")
            assert "Settings" not in ui.screen.display[0], ui.text()
            ui.key(b"\x1b[24~"); ui.wait("Heap")
            ui.key(b"\x1b[20;3~")
            ui.wait("− Process Manager")
            ui.mouse(2, 13, 1); ui.mouse(2, 13, 1, True)
            ui.choose("Restore"); ui.wait("Heap")
            ui.key(b"p"); ui.wait("Paused")  # Restoring also owns input.
            for size in [(32, 12), (1, 1), (100, 30)]: ui.resize(*size)
            ui.wait("Paused")
            ui.key(b"\x1b[23~"); ui.wait("Heap")
            ui.key(b"\x1b[23~"); ui.wait("Heap")
            elapsed = ui.quit()
            print(f"Monitor {'pack' if packed else 'source'}: hover, real metrics, pause, protected core, scoped end, restore; exit {elapsed:.3f}s")
        finally:
            ui.close()

if __name__ == "__main__":
    core_boot(False)
    core_boot(True)
    process_manager(False)
    process_manager(True)
    with fixture_workspace(presenter_probe=True, unit_tests=False) as project:
        pack = pack_fixture(project, project / "fixtures-deployment")
        exercise(False, project, pack)
        exercise(True, project, pack)
