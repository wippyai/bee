#!/usr/bin/env python3
"""Measure detached and PTY-attached standalone Bee owner CPU while idle."""

import os
import pathlib
import select
import subprocess
import tempfile
import time

from native_workspace import NativeDesktop
from workspace import database_environment


SAMPLE_SECONDS = float(os.environ.get("BEE_IDLE_CPU_SAMPLE_SECONDS", "60"))
DETACHED_LIMIT_PERCENT = float(os.environ.get("BEE_IDLE_CPU_LIMIT_PERCENT", "8.0"))
ATTACHED_LIMIT_PERCENT = float(os.environ.get("BEE_ATTACHED_IDLE_CPU_LIMIT_PERCENT", "3.0"))


def cpu_ticks(pid: int) -> int:
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[13]) + int(fields[14])


def sample_owner(pid: int, label: str, ticks_per_second: int, ui: NativeDesktop | None = None) -> float:
    before_ticks = cpu_ticks(pid)
    before_bytes = len(ui.raw) if ui is not None else 0
    started = time.monotonic()
    time.sleep(SAMPLE_SECONDS)
    elapsed = time.monotonic() - started
    used = (cpu_ticks(pid) - before_ticks) / ticks_per_second
    percent = used / elapsed * 100
    output = f"; PTY bytes={len(ui.raw) - before_bytes}" if ui is not None else ""
    print(f"{label} owner CPU: {percent:.2f}% ({used:.2f}s / {elapsed:.2f}s{output})", flush=True)
    return percent


def start_owner(binary: pathlib.Path, folder: pathlib.Path) -> subprocess.Popen:
    state = folder / "state"
    environment = database_environment(folder, HOME=str(folder), TERM="xterm-256color",
                                       PATH="/usr/bin:/bin", XDG_CONFIG_HOME=str(folder / ".config"))
    owner = subprocess.Popen(
        [str(binary), "--state", str(state), "daemon"],
        cwd=folder,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        ready = False
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            readable, _, _ = select.select([owner.stdout], [], [], 1)
            if not readable:
                if owner.poll() is not None:
                    break
                continue
            line = owner.stdout.readline()
            if not line:
                break
            if line.startswith("BEE_DAEMON_READY "):
                ready = True
                break
        if not ready:
            raise RuntimeError("standalone Bee owner did not become ready")
        return owner
    except BaseException:
        if owner.poll() is None:
            owner.terminate()
            try:
                owner.wait(timeout=10)
            except subprocess.TimeoutExpired:
                owner.kill()
                owner.wait()
        raise


def start_folder_owner(binary: pathlib.Path, folder: pathlib.Path) -> subprocess.Popen:
    state = folder / "state"
    environment = database_environment(folder, HOME=str(folder), TERM="xterm-256color",
                                       PATH="/usr/bin:/bin", XDG_CONFIG_HOME=str(folder / ".config"))
    owner = subprocess.Popen(
        [str(binary), "--state", str(state), "run", "start"],
        cwd=folder,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        ready = False
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            readable, _, _ = select.select([owner.stdout], [], [], 1)
            if not readable:
                if owner.poll() is not None:
                    break
                continue
            line = owner.stdout.readline()
            if not line:
                break
            if line.startswith("BEE_RETAINED_OWNER_READY "):
                ready = True
                break
        if not ready:
            raise RuntimeError("standalone Bee folder owner did not become ready")
        return owner
    except BaseException:
        stop_daemon(owner)
        raise


def stop_daemon(owner: subprocess.Popen) -> None:
    if owner.poll() is None:
        owner.terminate()
        try:
            owner.wait(timeout=10)
        except subprocess.TimeoutExpired:
            owner.kill()
            owner.wait()


def detached_leg(binary: pathlib.Path, folder: pathlib.Path, ticks_per_second: int) -> float:
    owner = start_owner(binary, folder)
    try:
        return sample_owner(owner.pid, "detached", ticks_per_second)
    finally:
        stop_daemon(owner)


def attached_legs(binary: pathlib.Path, folder: pathlib.Path, ticks_per_second: int) -> tuple[float, float]:
    state = folder / "state"
    owner = start_folder_owner(binary, folder)
    environment = database_environment(folder, HOME=str(folder), TERM="xterm-256color",
                                       PATH="/usr/bin:/bin", XDG_CONFIG_HOME=str(folder / ".config"))
    ui = NativeDesktop(binary, folder, state, environment=environment)
    try:
        ui.wait(" BEE ", timeout=30)

        ui.open_start()
        ui.choose("Settings")
        ui.wait("BEE SETTINGS", timeout=30)
        settings = sample_owner(owner.pid, "attached idle app", ticks_per_second, ui)

        ui.window_control("×")
        ui.wait_until(lambda: not any("Settings" in line and "×" in line for line in ui.screen.display),
                      "Settings window close", timeout=10)
        ui.open_start()
        start = sample_owner(owner.pid, "attached Start menu", ticks_per_second, ui)
        return start, settings
    finally:
        ui.close()
        stop_daemon(owner)


def main() -> int:
    binary = pathlib.Path(os.environ.get("BEE_BINARY", "dist/bee")).resolve()
    if not binary.is_file():
        raise SystemExit(f"standalone Bee binary not found: {binary}")
    ticks_per_second = os.sysconf("SC_CLK_TCK")
    with tempfile.TemporaryDirectory(prefix="bee-idle-cpu-detached-") as detached:
        detached_cpu = detached_leg(binary, pathlib.Path(detached), ticks_per_second)
    with tempfile.TemporaryDirectory(prefix="bee-idle-cpu-attached-") as attached:
        start_cpu, app_cpu = attached_legs(binary, pathlib.Path(attached), ticks_per_second)
    failures = []
    if detached_cpu > DETACHED_LIMIT_PERCENT:
        failures.append(f"detached owner CPU {detached_cpu:.2f}% exceeds {DETACHED_LIMIT_PERCENT:.2f}%")
    for label, percent in (("attached Start menu", start_cpu), ("attached idle app", app_cpu)):
        if percent > ATTACHED_LIMIT_PERCENT:
            failures.append(f"{label} owner CPU {percent:.2f}% exceeds {ATTACHED_LIMIT_PERCENT:.2f}%")
    if failures:
        raise RuntimeError("; ".join(failures))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as failure:
        raise SystemExit(str(failure)) from failure
