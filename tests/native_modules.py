"""Source-free Modules launch and input; catalog availability is not assumed."""
from pathlib import Path
import sys
import tempfile

from native_workspace import NativeDesktop
from native_client import stop_owner, live_owners, hold_owner


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bee-native-modules-") as temporary:
    folder = Path(temporary) / "project"
    folder.mkdir()
    state = Path(temporary) / "state"
    ui = NativeDesktop(binary, folder, state, application="bee.hub.modules:app")
    try:
        ui.wait("MODULES", timeout=20)
        ui.wait("Keyword: bee")
        ui.key(b"K")
        ui.wait("Filter by keyword")
        ui.key(b"\x7f\x7f\x7f\r")
        ui.wait("Keyword: all")
        ui.key(b"/")
        ui.key(b"terminal\r")
        ui.wait("Search: terminal")
        ui.key(b"\x1b[24~")
        ui.wait("MODULES", timeout=8)
        ui.wait("Keyword: all")
        ui.wait("Search: terminal")
        ui.resize(60, 20)
        ui.wait("MODULES")
        ui.key(b"o")
        ui.wait("MODULES  OPERATIONS")
        ui.wait("No Hub operations recorded")
        ui.key(b"\x1b[24~")
        ui.wait("MODULES  OPERATIONS", timeout=8)
        ui.wait("No Hub operations recorded")
        ui.quit()
    finally:
        ui.close()
        for pid in live_owners(binary, state):
            stop_owner(hold_owner(pid, binary, state))
print("Native Modules: admitted source-free launch, independent filters, F12, resize, real empty operation history and detach pass")
