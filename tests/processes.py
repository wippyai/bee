"""MIT. Portable process table and exit-observing handles for native fixtures.

The table comes from ps(1) on every platform. A handle names one process for
its lifetime: a pidfd on Linux and a kqueue NOTE_EXIT registration on macOS.
Callers open the handle first and then confirm the process identity, so a PID
recycled after a table scan is rejected before any signal is sent.
"""
from dataclasses import dataclass
import os
import select
import signal
import subprocess


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    state: str
    command: str


def _ps(*selection):
    result = subprocess.run(
        ['ps', *selection, '-ww', '-o', 'pid=,ppid=,stat=,args='],
        env={**os.environ, 'LC_ALL': 'C'}, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, errors='surrogateescape', check=False)
    rows = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 3)
        if len(fields) >= 3:
            rows.append(Process(int(fields[0]), int(fields[1]), fields[2],
                                fields[3] if len(fields) == 4 else ''))
    # ps -p exits 1 with no rows when the process is gone.
    if result.returncode != 0 and (rows or result.stderr.strip()):
        raise OSError(f'ps failed ({result.returncode}): {result.stderr.strip()}')
    return rows


def table():
    """Return every process visible to this user."""
    return _ps('-A')


def lookup(pid):
    """Return the process named by pid, or None when it is gone."""
    rows = _ps('-p', str(pid))
    return rows[0] if rows else None


def children(pid):
    """Return the direct children of pid."""
    return sorted(process.pid for process in table() if process.ppid == pid)


def command_line(*args):
    """Render an argument vector the way ps reports it."""
    return ' '.join(os.fspath(arg) for arg in args)


class ProcessHandle:
    """Exit-observing handle for one process."""

    def __init__(self, pid):
        self.pid = pid
        self._exited = False
        if hasattr(os, 'pidfd_open'):
            self._fd = os.pidfd_open(pid)
            self._queue = None
        elif hasattr(select, 'kqueue'):
            self._fd = None
            self._queue = select.kqueue()
            try:
                self._queue.control([select.kevent(
                    pid, filter=select.KQ_FILTER_PROC,
                    flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 0)
            except OSError:
                self._queue.close()
                raise
        else:
            raise OSError('process handles require pidfd or kqueue')

    def exited(self, timeout=0):
        """Report whether the process exits within timeout seconds."""
        if self._exited:
            return True
        if self._fd is not None:
            self._exited = bool(select.select([self._fd], [], [], timeout)[0])
        elif self._queue is not None:
            self._exited = bool(self._queue.control(None, 1, timeout))
        else:
            raise ValueError('process handle is closed')
        return self._exited

    def send_signal(self, number):
        """Deliver a signal while the process exit is unobserved."""
        if self._fd is not None:
            try:
                signal.pidfd_send_signal(self._fd, number)
            except ProcessLookupError:
                pass
            return
        if self._queue is None:
            raise ValueError('process handle is closed')
        # macOS has no descriptor-bound signal: a process that exits and is
        # reaped between the exit check and kill(2) leaves its PID open to reuse.
        if not self.exited():
            try:
                os.kill(self.pid, number)
            except ProcessLookupError:
                pass

    def stop(self, grace=10):
        """Terminate, escalate to SIGKILL after grace, and report the observed exit."""
        if self.exited():
            return True
        self.send_signal(signal.SIGTERM)
        if self.exited(grace):
            return True
        self.send_signal(signal.SIGKILL)
        return self.exited(5)

    def close(self):
        if self._fd is not None:
            os.close(self._fd)
            self._fd = None
        if self._queue is not None:
            self._queue.close()
            self._queue = None


def hold(pid, matches):
    """Hold pid only while matches accepts the process observed after opening."""
    try:
        handle = ProcessHandle(pid)
    except ProcessLookupError:
        return None
    process = lookup(pid)
    if process is not None and matches(process) and not handle.exited():
        return handle
    handle.close()
    return None
