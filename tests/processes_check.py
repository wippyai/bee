"""MIT. The portable process helper reports the same facts on Linux and macOS."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from processes import ProcessHandle, children, command_line, hold, lookup, table


def sleeper(marker):
    # The marker is one argument with a space, as fixture paths can be.
    return subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)', marker])


def main():
    assert any(process.pid == os.getpid() for process in table()), 'table omits this process'
    with tempfile.TemporaryDirectory(prefix='bee processes ') as temporary:
        marker = str(Path(temporary) / 'state')
        child = sleeper(marker)
        try:
            expected = command_line(sys.executable, '-c', 'import time; time.sleep(30)', marker)
            process = lookup(child.pid)
            assert process is not None and process.ppid == os.getpid(), process
            assert process.command == expected, (process.command, expected)
            assert process.state[:1] in {'R', 'S'}, process.state
            assert child.pid in children(os.getpid()), children(os.getpid())
            assert hold(child.pid, lambda observed: observed.command != expected) is None, 'hold ignored its predicate'
            handle = hold(child.pid, lambda observed: observed.command == expected)
            assert handle is not None, 'hold rejected the matching process'
            try:
                assert not handle.exited(), 'running process reported exit'
                assert not handle.exited(.05), 'running process reported exit after a bounded wait'
                handle.send_signal(signal.SIGSTOP)
                stopped = lookup(child.pid)
                for _ in range(100):
                    if stopped is not None and stopped.state.startswith('T'):
                        break
                    time.sleep(.02)
                    stopped = lookup(child.pid)
                assert stopped is not None and stopped.state.startswith('T'), stopped
                handle.send_signal(signal.SIGCONT)
                assert handle.stop(5), 'stop did not observe the exit'
                assert handle.exited(), 'observed exit was not retained'
                handle.send_signal(signal.SIGKILL)
            finally:
                handle.close()
            assert child.wait(5) == -signal.SIGTERM, child.returncode
            assert lookup(child.pid) is None, 'reaped process is still listed'
            try:
                ProcessHandle(child.pid).close()
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('a handle opened for a reaped process')
            assert hold(child.pid, lambda observed: True) is None, 'hold accepted a reaped process'
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    print('Process helper: table, lookup, children, identity hold, stop/continue, exit observation and reaped PIDs pass')


if __name__ == '__main__':
    main()
