"""Linux source-free public launcher: retained owner, local quit and clipboard."""
from pathlib import Path
import os
import fcntl
import subprocess
import select
import signal
import sys
import tempfile
import time

from native_workspace import NativeDesktop, STATE_ENVIRONMENT
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
            assert 'Starting Bee…'.encode() in ui.raw, 'Cold launch did not report its route'
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
            owner_logs = set(state.glob('owner-*.log'))
            rejoin_started = time.monotonic()
            ui = NativeDesktop(binary, folder, state)
            ui.wait('BEE_CLIENT_SELECTED', timeout=15)
            print(f'Warm client ready in {time.monotonic() - rejoin_started:.3f}s', flush=True)
            assert 'Connecting to Hive…'.encode() in ui.raw, 'Warm launch did not report its route'
            assert set(state.glob('owner-*.log')) == owner_logs, 'Warm client spawned another owner contender'
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


def preparing_owner(binary):
    with tempfile.TemporaryDirectory(prefix='bee-native-preparing-owner-') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        state.mkdir(mode=0o700)
        owner = None
        process = None
        ui = None
        try:
            with (state / '.application.lock').open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                ui = NativeDesktop(binary, folder, state)
                ui.pump(1)
                assert ui.process.poll() is None, bytes(ui.raw[-1000:])
                assert 'Connecting to Hive…'.encode() in ui.raw, 'Preparing-owner wait was blank'
                assert not list(state.glob('owner-*.log')), 'Waiting client spawned a contender'
            # Emulate the already-starting owner publishing after preparation.
            env = {key: value for key, value in os.environ.items()
                   if key not in STATE_ENVIRONMENT | {'BEE_RUNTIME', 'USER'}}
            env.update(TERM='xterm-256color', HOME=str(folder), PATH='/usr/bin:/bin')
            with tempfile.TemporaryFile() as output:
                process = subprocess.Popen([str(binary), '--state-dir', str(state),
                    '--command', 'bee', 'run', 'start'], cwd=folder, env=env,
                    stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True)
                owner = os.pidfd_open(process.pid)
                ui.wait(' BEE ', timeout=15)
                ui.quit()
                assert not select.select([owner], [], [], 0)[0], 'Waiting client killed owner'
        finally:
            if ui is not None:
                ui.close()
            stop_owner(owner)
            if process is not None:
                process.wait(timeout=5)
    print('Preparing owner: busy-lock client waits for publication, then authenticates and attaches')


def crashed_client(binary):
    with tempfile.TemporaryDirectory(prefix='bee-native-crashed-client-') as temporary:
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
            ui.key(b"BEE_CRASH_SHELL=$$; printf 'BEE_CRASH_%s\\n' READY\r")
            ui.wait('BEE_CRASH_READY')
            ui.process.kill()
            ui.process.wait(timeout=5)
            ui.close()
            ui = None
            # Exercise native node-departure delivery, not a synthetic EXIT.
            # Immediate exact-actor completion remains a separate runtime gate.
            time.sleep(40)
            assert not select.select([owner], [], [], 0)[0], 'Client crash killed the owner'
            ui = NativeDesktop(binary, folder, state)
            ui.wait('BEE_CRASH_READY', timeout=15)
            ui.key(b"test \"$BEE_CRASH_SHELL\" = \"$$\" && printf 'BEE_CRASH_%s\\n' RETAINED\r")
            ui.wait('BEE_CRASH_RETAINED')
            ui.quit()
            assert not select.select([owner], [], [], 0)[0], 'Reconnect stopped the owner'
        finally:
            if ui is not None:
                ui.close()
            stop_owner(owner)
    print('Client SIGKILL: native node departure revokes attachment; same owner and shell reconnect')


def command_launches(binary):
    """Cold and retained-owner aliases use the same admitted launch route."""
    with tempfile.TemporaryDirectory(prefix='bee-native-command-') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        owner = None
        ui = NativeDesktop(binary, folder, state, arguments=(
            'terminal', 'bash', '-c',
            'printf "%s\\n" "$1"; exec bash -i',
            'bee-command', 'COLD_LITERAL ; $(exit 4) words'))
        try:
            ui.wait('COLD_LITERAL ; $(exit 4) words', timeout=15)
            owner = owner_handle(ui, binary, state)
            ui.key(b"BEE_ALIAS_SHELL=$$; printf 'ALIAS_%s\\n' READY\r")
            ui.wait('ALIAS_READY')
            ui.quit()
            ui.close()
            ui = NativeDesktop(binary, folder, state, arguments=(
                'terminal', 'bash', '-c',
                'printf "%s\\n" "$1"; exec bash -i',
                'bee-command', 'WARM_LITERAL ; $(exit 4) words'))
            ui.wait('WARM_LITERAL ; $(exit 4) words', timeout=15)
            assert not select.select([owner], [], [], 0)[0], 'Alias replaced owner'
            ui.quit()
            ui.close()
            ui = NativeDesktop(binary, folder, state)
            ui.wait('WARM_LITERAL ; $(exit 4) words', timeout=15)
            ui.key(b'\x1b[24~')
            ui.wait('WARM_LITERAL ; $(exit 4) words')
            ui.quit()
        finally:
            ui.close()
            stop_owner(owner)
    print('Cold and warm command aliases preserve literal arguments and retained owner')


def observers(binary):
    """Public read-only attachment shares a live desktop without another app."""
    with tempfile.TemporaryDirectory(prefix='bee-native-observe-') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        missing = NativeDesktop(binary, folder, state, arguments=('observe',))
        try:
            missing.process.wait(timeout=3)
            missing.pump(.1)
            assert missing.process.returncode != 0
            assert b'No running Bee to observe' in missing.raw, bytes(missing.raw[-1000:])
            assert not list(state.glob('owner-*.log'))
        finally:
            missing.close()
        owner = None
        observer = None
        controller = NativeDesktop(binary, folder, state, arguments=('terminal', 'bash', '--noprofile', '--norc', '-i'))
        try:
            controller.wait('bash-', timeout=15)
            owner = owner_handle(controller, binary, state)
            controller.key(b"shared_bee=retained; printf 'PUBLIC_%s_OK\\n' \"$shared_bee\"\r")
            controller.wait('PUBLIC_retained_OK')
            observer = NativeDesktop(binary, folder, state, arguments=('observe',))
            observer.wait('PUBLIC_retained_OK', timeout=15)
            observer.key(b'forbidden_observer=yes\r')
            controller.key(b"printf 'OBSERVER_%s_%s_OK\\n' \"$shared_bee\" \"${forbidden_observer-unset}\"\r")
            controller.wait('OBSERVER_retained_unset_OK')
            observer.wait('OBSERVER_retained_unset_OK')
            assert observer.quit() < 1, 'Observer detach was not responsive'
            observer.close(); observer = None
            assert not select.select([owner], [], [], 0)[0], 'Observer exit stopped Bee'
            controller.key(b"printf 'AFTER_OBSERVE_%s_OK\\n' \"$shared_bee\"\r")
            controller.wait('AFTER_OBSERVE_retained_OK')
            controller.quit()
        finally:
            if observer is not None:
                observer.close()
            controller.close()
            stop_owner(owner)
    print('Public bee observe: absent Bee refused promptly; shared shell, denied typing, bounded detach and retained controller')


def idle_reconnects(binary):
    """Repeated graceful departures with idle gaps, against one retained Bee."""
    with tempfile.TemporaryDirectory(prefix='bee-idle-reconnects-') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        owner, ui = None, None
        try:
            ui = NativeDesktop(binary, folder, state)
            ui.wait(' BEE ', timeout=15)
            owner = owner_handle(ui, binary, state)
            ui.open_start()
            ui.choose('Terminal')
            ui.wait('Terminal')
            ui.key(b"BEE_RETAINED=alive; clear; printf 'IDLE_%s\\n' READY\r")
            ui.wait('IDLE_READY')
            ui.quit()
            ui.close()
            ui = None
            for attempt in range(8):
                time.sleep(20)
                started = time.monotonic()
                ui = NativeDesktop(binary, folder, state)
                ui.wait('IDLE_READY', timeout=8)
                print(f'Idle reconnect {attempt + 1}: {time.monotonic() - started:.3f}s', flush=True)
                ui.key(f"printf 'IDLE_{attempt + 1}_%s\\n' \"$BEE_RETAINED\"\r".encode())
                ui.wait(f'IDLE_{attempt + 1}_alive', timeout=3)
                ui.quit()
                ui.close()
                ui = None
            print('Eight idle reconnects retain the same Terminal and detach within one second')
        finally:
            if ui is not None:
                ui.close()
            stop_owner(owner)



def independent_desktops(binary):
    """The actual launcher reuses a detached desktop without stealing control."""
    import sqlite3
    with tempfile.TemporaryDirectory(prefix='bee-native-desktops-') as temporary:
        folder = Path(temporary)
        state = folder / 'state'
        owner = None
        clients = []
        def client(*arguments):
            ui = NativeDesktop(binary, folder, state, arguments=arguments)
            clients.append(ui)
            return ui
        def additional_count():
            database = state / 'workspace.db.client'
            assert database.exists(), f'Missing client store: {database}'
            with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
                return db.execute('SELECT count(*) FROM client_desktops').fetchone()[0]
        try:
            first = client()
            first.wait(' BEE ', timeout=15)
            owner = owner_handle(first, binary, state)
            first.open_start()
            first.choose('Terminal')
            first.wait('$ ')
            first.key(b"BEE_FIRST=original; clear; printf 'FIRST_%s\\n' READY\r")
            first.wait('FIRST_READY')
            second = client()
            second.wait(' BEE ', timeout=15)
            assert 'FIRST_READY' not in second.text(), second.text()
            second.open_start()
            second.choose('Terminal')
            second.wait('$ ')
            second.key(b"BEE_SECOND=retained; clear; printf 'SECOND_%s\\n' READY\r")
            second.wait('SECOND_READY')
            first.key(b"printf 'FIRST_STILL_%s\\n' \"$BEE_FIRST\"\r")
            first.wait('FIRST_STILL_original')
            assert additional_count() == 1, 'Second launch allocated duplicate desktops'
            observer = client('observe')
            observer.wait('FIRST_STILL_original', timeout=15)
            assert 'SECOND_READY' not in observer.text(), observer.text()
            observer.quit()
            observer.close()
            clients.remove(observer)
            second.key(b'\x1b[24~')
            second.wait('SECOND_READY')
            second.key(b"printf 'SECOND_F12_%s\\n' \"$BEE_SECOND\"\r")
            second.wait('SECOND_F12_retained')
            second.quit()
            second.close()
            clients.remove(second)
            second = client()
            second.wait('SECOND_F12_retained', timeout=15)
            second.key(b"printf 'SECOND_REJOIN_%s\\n' \"$BEE_SECOND\"\r")
            second.wait('SECOND_REJOIN_retained')
            assert additional_count() == 1, 'Reconnect allocated another desktop'
            third = client('terminal')
            third.wait('$ ', timeout=15)
            third.key(b"BEE_THIRD=independent; clear; printf 'THIRD_%s\\n' \"$BEE_THIRD\"\r")
            third.wait('THIRD_independent')
            assert 'SECOND_REJOIN_retained' not in third.text(), third.text()
            assert additional_count() == 2, 'Third controller did not get one independent desktop'
            second.key(b"printf 'SECOND_WITH_THIRD_%s\\n' \"$BEE_SECOND\"\r")
            second.wait('SECOND_WITH_THIRD_retained')
            first.key(b"printf 'FIRST_WITH_THIRD_%s\\n' \"$BEE_FIRST\"\r")
            first.wait('FIRST_WITH_THIRD_original')
            third.quit()
            second.quit()
            first.quit()
            assert not select.select([owner], [], [], 0)[0], 'Last display detach killed its applications'
        finally:
            for ui in reversed(clients):
                ui.close()
            stop_owner(owner)
    print('Public native Bee: three independent desktops, first-controller continuity, default observer, F12 and reuse without allocation passed')


if __name__ == '__main__':
    binary = Path(sys.argv[1]).resolve()
    if sys.argv[2:] == ['--idle-reconnects']:
        idle_reconnects(binary)
        sys.exit(0)
    if sys.argv[2:] == ['--desktops']:
        independent_desktops(binary)
        sys.exit(0)
    if sys.argv[2:] == ['--observe']:
        observers(binary)
        sys.exit(0)
    run(binary)
    observers(binary)
    independent_desktops(binary)
    command_launches(binary)
    stalled_detach(binary)
    preparing_owner(binary)
    crashed_client(binary)
