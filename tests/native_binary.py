"""Standalone Bee acceptance: no source or Wippy executable in the launch folder."""
from pathlib import Path
import sys
import tempfile
from native_workspace import NativeDesktop, STORE_NAMES
from terminal_selection import begin, copies
from terminal_scroll import scroll_terminal

BINARY = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bee-native-binary-") as temporary:
    folder = Path(temporary) / "empty launch folder"
    folder.mkdir()
    state = Path(temporary) / "bee state"
    ui = NativeDesktop(BINARY, folder, state, "bee.settings:app")
    try:
        ui.wait("Settings")
        ui.key(b"\x1b[24~")
        ui.wait("Settings")
        ui.quit()
    finally:
        ui.close()
    for filename in [f"{name}.db" for name in STORE_NAMES] + ["workspace.db.client"]:
        database = state / filename
        assert database.is_file(), f"{filename} did not use the selected native state directory"
        with database.open("rb") as handle:
            assert handle.read(16) == b"SQLite format 3\0", f"{filename} is not an initialized SQLite store"
    deployments = list((state / "deployments").glob("*/wippy.lock"))
    assert len(deployments) == 1, "No digest-scoped embedded deployment"
    assert (state / "registry.db").is_file(), "Ordinary launch lost its shared registry history"
    assert not (state / "recovery" / "registry.db").exists(), "Ordinary launch selected recovery history"
    recovery = NativeDesktop(BINARY, folder, state, arguments=("recover",))
    try:
        recovery.wait(" BEE ")
        recovery.quit()
    finally:
        recovery.close()
    assert (state / "recovery" / "registry.db").is_file(), "Recovery launch did not isolate registry history"
    # This suite verifies explicit in-process application launches. The public
    # owner/client route (which retains its owner after exit) is exercised by
    # native_client.py with explicit fixture-owned process cleanup.
    ui = NativeDesktop(BINARY, folder, state, "bee.settings:app")
    try:
        ui.wait("Settings")
        ui.quit()
    finally:
        ui.close()
    ui = NativeDesktop(BINARY, folder, state, "bee.console:app")
    try:
        ui.wait("Terminal")
        ui.key(b"printf '\\102\\105\\105\\137\\116\\101\\124\\111\\126\\105\\137\\117\\113\\n'\r")
        ui.wait("BEE_NATIVE_OK")
        x, y = begin(ui, "BEE_NATIVE_OK")
        copied_after = len(ui.raw)
        ui.mouse(0, x, y)
        ui.mouse(32, x + len("BEE_NATIVE_OK") - 1, y)
        ui.mouse(0, x + len("BEE_NATIVE_OK") - 1, y, True)
        ui.key(b"\x03")
        ui.wait("Clipboard request submitted")
        assert copies(ui, copied_after) == ["BEE_NATIVE_OK"], "Standalone copy did not use its physical output"
        ui.key(b"\x1b[24~")
        ui.wait("BEE_NATIVE_OK")
        scroll_terminal(ui)
        ui.quit(confirm=True)
    finally:
        ui.close()
    assert not (folder / ".wippy").exists(), "Native host wrote runtime state into the caller directory"
    assert not (folder / ".wippy").exists(), "Native host wrote runtime state into the caller directory"
print("Standalone Bee: embedded boot, Settings recovery, terminal, wheel/burst scrolling and physical selection/copy passed")
