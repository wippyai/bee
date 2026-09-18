"""Verify About uses embedded standalone build identity."""
import json
import os
from pathlib import Path
import sys
import tempfile
from native_workspace import NativeDesktop
from native_client import stop_owner, live_owners, owner_pidfd

binary = Path(sys.argv[1]).resolve()
provenance = json.loads(Path(str(binary) + ".provenance.json").read_text())
manifest = provenance["manifest"]
with tempfile.TemporaryDirectory(prefix="bee-native-about-") as temporary:
    project = Path(temporary) / "project"
    project.mkdir()
    state = Path(temporary) / "state"
    ui = NativeDesktop(binary, project, state, application="bee.settings:app")
    try:
        ui.wait("BEE SETTINGS", timeout=20)
        ui.key(b"\t\t\t")
        ui.wait("BEE SETTINGS · ABOUT")
        initial = ui.text()
        assert "development (unknown)" not in initial, initial
        expected = os.environ.get("BEE_ABOUT_SOURCE", "")
        if expected:
            assert expected[:12] in initial, initial
        ui.key(b"\x1b[6~" * 30)
        ui.wait("https://bee.wippy.ai")
        combined = initial + ui.text()
        assert manifest["runtime"]["commit"] in combined, combined
        for native in manifest["native"]:
            assert native["version"] in combined, combined
        ui.key(b"\x1b[24~")
        ui.wait("https://bee.wippy.ai")
        ui.resize(48, 16)
        ui.key(b"\x1b[6~" * 30)
        ui.wait("Website")
        ui.quit()
    finally:
        ui.close()
        for pid in live_owners(binary, state):
            stop_owner(owner_pidfd(pid, binary, state))
print("Native About: embedded build/runtime/native identity, F12 and narrow scrolling pass")
