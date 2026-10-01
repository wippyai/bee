# SPDX-License-Identifier: MIT
"""Opt-in live Bee pack update and offline restart against private Hub releases."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

from native_client import hold_owner, live_owners, stop_owner
from native_workspace import NativeDesktop


def exercise(args, scratch, phase):
    folder, state, home = (scratch / name for name in ("project", "state", "home"))
    environment = dict(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                       TMPDIR=str(scratch / "tmp"), TERM="xterm-256color",
                       LC_ALL="C.UTF-8", PATH="/usr/bin:/bin:/usr/sbin")
    if phase == "offline":
        interfaces = subprocess.check_output(["ip", "-o", "link"], text=True)
        assert len(interfaces.splitlines()) == 1 and ": lo:" in interfaces, interfaces
        subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
        with socket.socket() as probe:
            try:
                probe.connect(("1.1.1.1", 443))
            except OSError as error:
                print(f"Offline: loopback only; external connection refused: {error}", flush=True)
            else:
                raise AssertionError("external network remains reachable")
    ui, owner = None, None

    def frame(name):
        text = "\n".join(line.rstrip() for line in ui.screen.display)
        path = args.evidence / f"{name}.frame.txt"
        path.write_text(text + "\n")
        print(f"Frame: {path}", flush=True)

    def tab(label, containing):
        for y, line in enumerate(ui.screen.display, 1):
            if label in line and containing in line:
                x = line.index(label) + 1
                ui.mouse(0, x, y)
                ui.mouse(0, x, y, True)
                return
        raise AssertionError(f"missing {label} tab: {ui.text()}")

    def about(name, expected, marker=False):
        ui.open_start()
        ui.choose("Settings")
        ui.wait("BEE SETTINGS", timeout=30)
        ui.key(b"\x1b[23~")
        tab("About", "Themes")
        ui.wait("BEE SETTINGS · ABOUT", timeout=30)
        ui.wait("bee/bee  installed", timeout=180)
        ui.wait(expected, timeout=180)
        if marker:
            ui.wait(args.marker, timeout=30)
        frame(name)

    try:
        ui = NativeDesktop(args.binary, folder, state, environment=environment)
        ui.wait(" BEE ", timeout=30)
        ui.resize(150, 50)
        owners = live_owners(args.binary, state)
        assert len(owners) == 1, owners
        pid = owners[0]
        owner = hold_owner(pid, args.binary, state)
        pids = {"owner_before": pid, "client": ui.process.pid}
        (args.evidence / f"{phase}.pids.json").write_text(json.dumps(pids) + "\n")
        print(f"{phase}: owner PID {pid}; client PID {ui.process.pid}", flush=True)
        if phase == "live":
            about("01-baseline-about", "update available")
            assert f"installed {args.from_version}" in ui.text(), ui.text()
            assert f"Hub {args.to_version}" in ui.text(), ui.text()
            ui.window_control("×")
            ui.open_start()
            for item in ("Apps", "Advanced", "Modules"):
                ui.choose(item)
            ui.wait("MODULES", timeout=30)
            ui.key(b"\x1b[23~")
            tab("Installed", "Installed")
            ui.wait("MODULES  INSTALLED", timeout=30)
            ui.wait("Update Bee", timeout=180)
            frame("02-modules-installed")
            ui.key(b"u")
            ui.wait_until(lambda: any(text in ui.text() for text in (
                "Ready for confirmation", "needs a newer Bee binary", "PLAN:", "INVALID:", "Missing:")),
                "self-update plan", timeout=180)
            frame("03-plan")
            assert "Ready for confirmation" in ui.text(), ui.text()
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM", timeout=30)
            frame("04-confirm")
            ui.key(b"\r")
            ui.wait("MODULES  RESULT", timeout=180)
            frame("05-apply-result")
            after = live_owners(args.binary, state)
            assert after == [pid] and not owner.exited(), after
            pids["owner_after"] = after[0]
            (args.evidence / "live.pids.json").write_text(json.dumps(pids) + "\n")
            print(f"Apply returned: owner PID before {pid}; after {after[0]}", flush=True)
            assert "Completed:" in ui.text() and "Receipt state: complete" in ui.text(), ui.text()
            ui.window_control("×")
            about("06-live-about", f"installed {args.to_version}", marker=True)
            assert live_owners(args.binary, state) == [pid] and not owner.exited()
        else:
            about("07-offline-about", f"installed {args.to_version}", marker=True)
        (args.evidence / f"{phase}.pids.json").write_text(json.dumps(pids) + "\n")
        ui.quit()
        ui.close()
        ui = None
        stopped = subprocess.run([str(args.binary), "--state", str(state), "stop"],
                                 cwd=folder, env=environment, text=True, capture_output=True, timeout=30)
        assert stopped.returncode == 0, stopped.stdout + stopped.stderr
        assert not live_owners(args.binary, state)
        owner.close()
        owner = None
        print(f"{phase} PASS: owner stopped cleanly", flush=True)
    except Exception:
        if ui is not None:
            frame(f"{phase}-failure")
        errors = []
        for log in state.glob("owner-*.log"):
            for line in log.read_text(errors="replace").splitlines():
                if "dependency resolution failed" in line or "failed to expand changeset" in line:
                    errors.append(line)
        if errors:
            (args.evidence / f"{phase}-owner-errors.log").write_text("\n".join(errors) + "\n")
        raise
    finally:
        if ui is not None:
            ui.close()
        if owner is not None:
            stop_owner(owner)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--from-version", required=True)
    parser.add_argument("--to-version", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--offline-scratch", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not all((args.from_version, args.to_version, args.marker, str(args.evidence))):
        parser.error("versions, visible marker and evidence directory must be nonempty")
    args.binary = args.binary.resolve()
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=True)
    if args.offline_scratch:
        exercise(args, args.offline_scratch, "offline")
        return
    root = Path(__file__).resolve().parents[1]
    (root / ".wippy").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="self-update-proof-", dir=root / ".wippy") as directory:
        scratch = Path(directory)
        for name in ("project", "tmp", "home/.config"):
            (scratch / name).mkdir(parents=True)
        config = Path.home() / ".config/wippy"
        assert config.is_dir(), "Wippy Hub login config is required"
        (scratch / "home/.config/wippy").symlink_to(config, target_is_directory=True)
        exercise(args, scratch, "live")
        subprocess.run(["unshare", "--user", "--map-root-user", "--net", "--", sys.executable,
                        str(Path(__file__).resolve()), str(args.binary),
                        "--from-version", args.from_version, "--to-version", args.to_version,
                        "--marker", args.marker, "--evidence", str(args.evidence),
                        "--offline-scratch", str(scratch)], check=True)
    print("Live/offline self-update PASS; scratch HOME and state removed", flush=True)


if __name__ == "__main__":
    main()
