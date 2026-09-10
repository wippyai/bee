"""Linux source-free public launcher: retained owner, local quit and clipboard."""
from pathlib import Path
import os
import select
import signal
import sys
import tempfile
import time

from native_workspace import NativeDesktop
from terminal_selection import begin, copies


def owner_handle(ui, binary, state):
    # Capture only this test client's actual child, then hold its kernel identity
    # so cleanup cannot signal a recycled PID or an unrelated user's owner.
    children = set()
    for task in Path(f'/proc/{ui.process.pid}/task').glob('*/children'):
        children.update(task.read_text().split())
    for child in children:
        handle = os.pidfd_open(int(child))
        args = Path(f'/proc/{child}/cmdline').read_bytes().split(b'\0')
        if args[0] == os.fsencode(binary) and os.fsencode(state) in args and b'start' in args:
            return handle
        os.close(handle)
    raise AssertionError('Automatic launch did not create its retained owner')


def stop_owner(owner):
    if owner is None:
        return
    try:
        if not select.select([owner], [], [], 0)[0]:
            signal.pidfd_send_signal(owner, signal.SIGTERM)
            if not select.select([owner], [], [], 10)[0]:
                signal.pidfd_send_signal(owner, signal.SIGKILL)
                assert select.select([owner], [], [], 5)[0], 'Fixture owner failed to exit'
    finally:
        os.close(owner)


def run(binary):
    with tempfile.TemporaryDirectory(prefix='bee-native-client-') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        owner = None
        ui = NativeDesktop(binary, folder, state)
        try:
            ui.wait(' BEE ', timeout=15)
            owner = owner_handle(ui, binary, state)
            ui.open_start()
            ui.choose('Terminal')
            ui.wait('Terminal')
            ui.key(b"BEE_RETAINED=alive; clear; printf 'BEE_CLIENT_%s\\n' SELECTED\r")
            ui.wait('BEE_CLIENT_SELECTED')
            x, y = begin(ui, 'BEE_CLIENT_SELECTED')
            start = len(ui.raw)
            ui.mouse(0, x, y)
            ui.mouse(32, x + len('BEE_CLIENT_SELECTED') - 1, y)
            ui.mouse(0, x + len('BEE_CLIENT_SELECTED') - 1, y, True)
            ui.key(b'\x03')
            deadline = time.monotonic() + 5
            while not copies(ui, start) and time.monotonic() < deadline:
                ui.pump(.05)
            assert copies(ui, start) == ['BEE_CLIENT_SELECTED'], ui.text()
            ui.quit()
            ui.close()
            assert not select.select([owner], [], [], 0)[0], 'Client quit killed the owner'
            ui = NativeDesktop(binary, folder, state)
            ui.wait('BEE_CLIENT_SELECTED', timeout=15)
            ui.key(b"printf 'BEE_REJOIN_%s\\n' \"$BEE_RETAINED\"\r")
            ui.wait('BEE_REJOIN_alive')
            ui.key(b'\x1b[24~')
            ui.wait('BEE_REJOIN_alive')
            assert not copies(ui, 0), 'Rejoin replayed a clipboard request'
            ui.quit()
            assert not select.select([owner], [], [], 0)[0], 'Second client quit killed the owner'
        except AssertionError:
            print(f'Client exit={ui.process.poll()}, output tail={bytes(ui.raw[-1600:])!r}', file=sys.stderr)
            if os.environ.get('BEE_NATIVE_STACK') and ui.process.poll() is None:
                ui.process.send_signal(signal.SIGQUIT)
                ui.pump(3)
                Path(os.environ['BEE_NATIVE_STACK']).write_bytes(ui.raw)
            raise
        finally:
            ui.close()
            stop_owner(owner)
    print('Public native Bee: cold owner, exact copy, Ctrl+Q detach, retained shell, F12 and no clipboard replay passed')


def stalled_detach(binary):
    with tempfile.TemporaryDirectory(prefix='bee-native-stalled-detach-') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        owner = None
        ui = NativeDesktop(binary, folder, state)
        try:
            ui.wait(' BEE ', timeout=15)
            owner = owner_handle(ui, binary, state)
            # Fault injection against this fixture's held process identity only.
            signal.pidfd_send_signal(owner, signal.SIGSTOP)
            start = time.monotonic()
            os.write(ui.master, bytes([17]))
            while ui.process.poll() is None and time.monotonic() - start < 2:
                ui.pump(.02)
            assert ui.process.poll() is not None, 'Local detach waited for the stalled owner'
            assert bytes([27]) + b'[?1049l' in ui.raw, 'Physical terminal was not restored'
            assert b'detach desktop:' in ui.raw, 'Unacknowledged detach reported as committed'
            assert b'outcome is unknown' in ui.raw, bytes(ui.raw[-500:])
            assert not select.select([owner], [], [], 0)[0], 'Detach stopped the owner'
        finally:
            if owner is not None:
                signal.pidfd_send_signal(owner, signal.SIGCONT)
            ui.close()
            stop_owner(owner)
    print('Stalled owner: bounded physical exit, uncertainty preserved, owner retained')


if __name__ == '__main__':
    binary = Path(sys.argv[1]).resolve()
    run(binary)
    stalled_detach(binary)
