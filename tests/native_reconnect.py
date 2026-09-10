"""MIT. Linux overlapping-display diagnostic against an assembled Bee binary.

Uses disposable stores. Failed fixtures retain frames, a read-only catalog probe
and an exact-process stack; successful fixtures are removed. This is an opt-in
stress check, not evidence of complete remote recovery.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import select
import shutil
import signal
import subprocess
import tempfile
import time

from native_client import owner_handle, stop_owner
from native_workspace import NativeDesktop


def run(binary, rounds):
    folder = Path(tempfile.mkdtemp(prefix="bee-native-reconnect-"))
    state = folder / "state"
    owner = None
    clients = []
    passed = False
    print(f"Fixture {folder}", flush=True)

    def join():
        nonlocal owner
        started = time.monotonic()
        ui = NativeDesktop(binary, folder, state)
        try:
            ui.wait(" BEE ", timeout=20)
            return ui, time.monotonic() - started
        except BaseException:
            (folder / f"failed-{ui.process.pid}.raw").write_bytes(ui.raw)
            # A cold launch may start its retained child before the first frame
            # fails. Capture that exact child before closing the launcher.
            if owner is None:
                try:
                    owner = owner_handle(ui, binary, state)
                except (AssertionError, OSError):
                    pass
            ui.close()
            raise

    try:
        first, _ = join()
        clients.append(first)
        owner = owner_handle(first, binary, state)
        first.open_start()
        first.choose("Tools")
        first.choose("Hive Manager")
        first.wait("HIVE MANAGER", timeout=10)
        first.quit()
        first.close()
        clients.clear()
        with ThreadPoolExecutor(max_workers=3) as pool:
            for cycle in range(rounds):
                futures = [pool.submit(join) for _ in range(3)]
                failures, durations = [], []
                # Collect every result, including successful peers of a failed
                # launch, so their physical clients are always cleaned up.
                for future in futures:
                    try:
                        ui, duration = future.result()
                        clients.append(ui)
                        durations.append(round(duration, 3))
                    except BaseException as error:
                        failures.append(error)
                if failures:
                    raise failures[0]
                for ui in clients:
                    ui.pump(.15)
                for ui in reversed(clients):
                    ui.quit()
                    ui.close()
                clients.clear()
                print(f"Round {cycle + 1}: three frames {durations}", flush=True)
        passed = True
        print(f"{rounds} overlapping three-client reconnects passed", flush=True)
    except BaseException:
        for ui in clients:
            (folder / f"client-{ui.process.pid}.raw").write_bytes(ui.raw)
        # Establish whether the service still answers BEFORE capturing its
        # stack. Keep surviving clients drained during this read-only probe.
        if owner is not None and not select.select([owner], [], [], 0)[0]:
            started = time.monotonic()
            with subprocess.Popen([str(binary), "--state-dir", str(state), "desktops"],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as probe:
                while True:
                    try:
                        output, _ = probe.communicate(timeout=.05)
                        break
                    except subprocess.TimeoutExpired:
                        if time.monotonic() - started > 65:
                            probe.kill()
                            output, _ = probe.communicate()
                            break
                        for ui in clients:
                            if ui.process.poll() is None:
                                ui.pump(.01)
                report = f"elapsed={time.monotonic() - started:.3f} exit={probe.returncode}\n"
                (folder / "failure-catalog.txt").write_bytes(report.encode() + output)
                print(f"Post-failure catalog: {report.strip()}", flush=True)
            if not select.select([owner], [], [], 0)[0]:
                signal.pidfd_send_signal(owner, signal.SIGQUIT)
                select.select([owner], [], [], 5)
        print(f"Failure evidence preserved in {folder}", flush=True)
        raise
    finally:
        try:
            for ui in clients:
                ui.close()
        finally:
            stop_owner(owner)
        if passed:
            shutil.rmtree(folder)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--rounds", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 1000:
        parser.error("rounds must be between 1 and 1000")
    run(args.binary.resolve(strict=True), args.rounds)
