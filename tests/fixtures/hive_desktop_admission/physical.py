#!/usr/bin/env python3
# MIT. Test-only PTY driver around the compiled native desktop client.
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import pyte


MAX_OUTPUT = 8 * 1024 * 1024
CRASH_ATTEMPTS = 20
CRASH_RETRY_DELAY = 0.25
RETRYABLE_ATTACH_REFUSALS = (
    b"physical attach: BUSY: Desktop request already pending",
    b"physical attach: UNAVAILABLE: Desktop is starting",
    b"physical attach: UNAVAILABLE: Desktop already has a controller",
    b"physical attach: UNAVAILABLE: Previous connection is being revoked",
    b"physical attach: UNAVAILABLE: Desktop session is closing",
)


def probe():
    binary = os.environ["BEE_NATIVE_DESKTOP_PHYSICAL_BINARY"]
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
    original_attributes = termios.tcgetattr(slave)
    output = bytearray()
    pending_frame = bytearray()
    screen = pyte.Screen(100, 32)
    stream = pyte.ByteStream(screen)
    children = []

    def append_output(data):
        if data:
            output.extend(data)
            pending_frame.extend(data)
            # Publish complete physical frames; a diff may contain only a PID
            # suffix, and unchanged Terminal text remains on the screen.
            end_frame = b"\x1b[?2026l"
            while (end := pending_frame.find(end_frame)) >= 0:
                end += len(end_frame)
                stream.feed(bytes(pending_frame[:end]))
                del pending_frame[:end]
            if len(output) > MAX_OUTPUT:
                raise AssertionError("physical output exceeded bound")

    def read_available(child):
        """Read all currently queued PTY output without blocking."""
        read_any = False
        while select.select([master], [], [], 0)[0]:
            try:
                data = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    if child.poll() is None:
                        raise AssertionError(
                            f"physical terminal closed: {bytes(output[-3000:])!r}"
                        ) from exc
                    return read_any
                raise
            if not data:
                return read_any
            append_output(data)
            read_any = True
        return read_any

    def drain_after_exit(child, timeout=0.5):
        """Drain diagnostics written just before an exited child closed its PTY fd."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if read_available(child):
                continue
            remaining = max(0, deadline - time.monotonic())
            if not remaining or not select.select([master], [], [], remaining)[0]:
                return

    def wait_for_prompt(child, needle=b"$ ", timeout=15):
        deadline = time.monotonic() + timeout
        while needle not in output:
            read_available(child)
            if needle in output:
                return True
            if child.poll() is not None:
                drain_after_exit(child)
                return False
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    f"physical client missing {needle!r}: {bytes(output[-3000:])!r}"
                )
            select.select([master], [], [], min(0.1, remaining))
        return True

    def wait_for_exit(child, timeout, reason):
        deadline = time.monotonic() + timeout
        while child.poll() is None:
            read_available(child)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"{reason} exceeded {timeout:g} seconds")
            select.select([master], [], [], min(0.05, remaining))
        child.wait()
        drain_after_exit(child)
        return child.returncode

    def presenter():
        match = re.search(r" P:([^\s]+)", screen.display[0])
        return match.group(1) if match else None

    def wait_for_replacement(child, previous):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            read_available(child)
            if presenter() not in (None, previous) and "PHYSICAL_alive_OK" in "\n".join(screen.display):
                return
            if child.poll() is not None:
                raise child_error(child, "client exited during F12 replacement:")
            select.select([master], [], [], .05)
        raise child_error(child, "F12 did not replace presenter with retained content:")

    def child_error(child, description):
        return AssertionError(
            f"{description} {child.returncode}: {bytes(output[-3000:])!r}"
        )

    def start_child(directory=None):
        child = subprocess.Popen(
            [binary],
            cwd=directory,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            env={
                **os.environ,
                "TERM": "xterm-256color",
                "BEE_NATIVE_DESKTOP_PHYSICAL": "1",
            },
            start_new_session=True,
        )
        children.append(child)
        return child

    def command(text):
        os.write(master, text.encode() + b"\r")

    def check_owner_proof(child):
        token = os.environ.get("BEE_NATIVE_DESKTOP_OWNER_PROOF")
        if token is None or token == "":
            return
        command("printf 'OWNER_%s_OK\\n' \"$(cat desktop-owner-proof)\"")
        if not wait_for_prompt(child, b"OWNER_" + token.encode() + b"_OK"):
            raise child_error(child, "physical owner proof failed:")

    def crash_rejoin(child):
        if child.poll() is not None:
            raise child_error(child, "physical crash client exited before SIGKILL:")
        os.kill(child.pid, signal.SIGKILL)
        try:
            returncode = child.wait(timeout=5)
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(
                "physical SIGKILL child did not exit within five seconds"
            ) from exc
        drain_after_exit(child)
        if returncode != -signal.SIGKILL:
            raise child_error(child, "physical crash client did not exit from SIGKILL:")

        # SIGKILL leaves the PTY in the client's raw mode. Restore the captured
        # baseline before a fresh client takes ownership of the same terminal.
        termios.tcsetattr(slave, termios.TCSANOW, original_attributes)
        output.clear()

        rejoin_directory = os.environ.get("BEE_NATIVE_DESKTOP_REJOIN_DIR")
        if not rejoin_directory:
            raise AssertionError("fresh identity rejoin directory is required")
        fresh = None
        for attempt in range(CRASH_ATTEMPTS):
            fresh = start_child(rejoin_directory)
            if wait_for_prompt(fresh):
                break
            if fresh.returncode == 0 or not any(
                refusal in output for refusal in RETRYABLE_ATTACH_REFUSALS
            ):
                raise child_error(fresh, "physical crash rejoin failed:")
            if attempt + 1 == CRASH_ATTEMPTS:
                raise child_error(
                    fresh, "physical crash rejoin exhausted attach retries:"
                )
            output.clear()
            time.sleep(CRASH_RETRY_DELAY)
        else:
            raise AssertionError("physical crash rejoin did not start a fresh client")

        command("printf 'PHYSICAL_CRASH_REJOIN_%s_OK\\n' \"$native_pty\"")
        if not wait_for_prompt(fresh, b"PHYSICAL_CRASH_REJOIN_crash_retained_OK"):
            raise child_error(fresh, "physical crash rejoin marker missing:")

        os.write(master, b"\x1d")
        returncode = wait_for_exit(
            fresh, 8, "physical crash rejoin Ctrl+] detach"
        )
        if returncode != 0:
            raise child_error(fresh, "physical crash rejoin detach exited")
        if termios.tcgetattr(master) != original_attributes:
            raise AssertionError(
                "physical crash rejoin detach did not restore terminal attributes"
            )

    try:
        child = start_child()
        if not wait_for_prompt(child):
            raise child_error(child, "physical client exited before prompt:")
        check_owner_proof(child)
        if os.environ.get("BEE_NATIVE_DESKTOP_PHYSICAL_CRASH") == "1":
            command(
                "native_pty=crash_retained; printf 'PHYSICAL_CRASH_%s_OK\\n' \"$native_pty\""
            )
            if not wait_for_prompt(child, b"PHYSICAL_CRASH_crash_retained_OK"):
                raise child_error(child, "physical crash marker missing:")
            crash_rejoin(child)
        else:
            command("native_pty=alive; printf 'PHYSICAL_%s_OK\\n' \"$native_pty\"")
            if not wait_for_prompt(child, b"PHYSICAL_alive_OK"):
                raise child_error(child, "physical marker missing:")
            # F12 is handled by the retained desktop; its Terminal stays alive.
            read_available(child)
            previous = presenter()
            if previous is None:
                raise AssertionError("missing fixture presenter marker")
            os.write(master, b"\x1b[24~")
            output.clear()
            wait_for_replacement(child, previous)
            screen.resize(40, 120)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            os.killpg(child.pid, signal.SIGWINCH)
            command("printf 'RESIZED_%s_OK\\n' \"$native_pty\"")
            if not wait_for_prompt(child, b"RESIZED_alive_OK"):
                raise child_error(child, "physical resize marker missing:")
            os.write(master, b"\x1d")
            returncode = wait_for_exit(child, 8, "physical Ctrl+] detach")
            if returncode != 0:
                raise child_error(child, "physical detach exited")
            if termios.tcgetattr(master) != original_attributes:
                raise AssertionError("physical detach did not restore terminal attributes")
        if b"WARNING: DATA RACE" in output:
            raise AssertionError("native client race report")
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        os.close(slave)
        os.close(master)


print("BEE_HIVE_SUPERVISOR ready physical-pty-driver", flush=True)
for line in sys.stdin:
    if line.strip() == "probe":
        probe()
        print("BEE_HIVE_SUPERVISOR probe_passed", flush=True)
    elif line.strip() == "stop":
        print("BEE_HIVE_SUPERVISOR stopped", flush=True)
        break
    else:
        raise AssertionError("unsupported physical fixture command")
