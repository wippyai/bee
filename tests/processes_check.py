"""MIT. The portable process helper reports the same facts on Linux and macOS."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from processes import ProcessHandle, children, command_line, hold, lookup, table


def sleeper(marker):
    # The marker is one argument with a space, as fixture paths can be. tail keeps
    # the argument vector it was started with; a macOS framework Python relaunches
    # itself with argv[0] rewritten, so its ps row changes after it starts.
    Path(marker).touch()
    tail = shutil.which('tail')
    assert tail is not None, 'tail is not on PATH'
    argv = [tail, '-f', marker]
    return subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL), command_line(*argv)


def refuses(pid, predicate):
    """Return None when hold refuses pid, or the rows ps reported around the accepted hold."""
    observed = []

    def recorded(process):
        observed.append(process)
        return predicate(process)

    handle = hold(pid, recorded)
    if handle is None:
        return None
    handle.close()
    return observed, lookup(pid)


def main():
    assert any(process.pid == os.getpid() for process in table()), 'table omits this process'
    with tempfile.TemporaryDirectory(prefix='bee processes ') as temporary:
        marker = str(Path(temporary) / 'state')
        child, expected = sleeper(marker)
        try:
            process = lookup(child.pid)
            assert process is not None and process.ppid == os.getpid(), process
            assert process.command == expected, (process.command, expected)
            assert process.state[:1] in {'R', 'S'}, process.state
            assert child.pid in children(os.getpid()), children(os.getpid())
            accepted = refuses(child.pid, lambda observed: observed.command != expected)
            assert accepted is None, ('hold ignored its predicate', expected, process, *accepted)
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
