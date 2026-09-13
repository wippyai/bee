"""Live Hub proof: inspect a public package through the standalone Modules UI."""
import hashlib
from pathlib import Path
import sys
import tempfile
from native_workspace import NativeDesktop
from native_client import stop_owner, live_owners, owner_pidfd

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bee-native-contents-") as directory:
    root = Path(directory)
    project, state = root / "project", root / "state"
    project.mkdir()
    ui = NativeDesktop(binary, project, state, application="bee.modules:app")
    try:
        def click_text(text):
            for y, row in enumerate(ui.screen.display, 1):
                if text in row:
                    x = row.index(text) + 1
                    ui.mouse(0, x, y)
                    ui.mouse(0, x, y, True)
                    return
            raise AssertionError(f"Missing click target {text!r}\n{ui.text()}")

        def base_hashes():
            return {str(p.relative_to(state)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in state.glob("base/**/vendor/bee/*.wapp")}

        ui.wait("MODULES", timeout=20)
        baseline = base_hashes()
        assert baseline, "embedded base not materialized"
        ui.key(b"K")
        ui.wait("Filter by keyword")
        ui.key(b"\x7f\x7f\x7f\r")
        ui.wait("Keyword: all")
        ui.key(b"/")
        ui.wait("Search packages")
        ui.key(b"test\r")
        ui.wait("Test Framework", timeout=30)
        click_text("wippy/test")
        ui.wait("Version 0.")
        ui.key(b"v")
        ui.wait("0.4.17")
        click_text("0.4.17")
        ui.key(b"c")
        ui.wait("Read-only package contents", timeout=30)
        ui.wait("entries and resources", timeout=30)
        ui.key(b"\r")
        ui.wait("Read-only entry definition")
        ui.key(b"\x1b[24~")
        ui.wait("Read-only entry definition")
        ui.resize(48, 18)
        ui.wait("Read-only entry definition")
        click_text("Installed")
        ui.wait("Your installed packages", timeout=20)
        assert "wippy/test" not in ui.text(), "preview installed the selected package"
        current = base_hashes()
        assert all(current.get(path) == digest for path, digest in baseline.items()), "preview changed bundled artifacts"
        ui.quit()
    except Exception:
        print(ui.text())
        raise
    finally:
        ui.close()
        for pid in live_owners(binary, state):
            stop_owner(owner_pidfd(pid, binary, state))
print("Native live Contents: public exact-version entries, definition preview, rejoin/resize, no installation and unchanged base passed")
