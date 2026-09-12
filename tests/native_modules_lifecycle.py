"""Native source-free Modules install, update and uninstall acceptance.

Each operation goes through the rendered confirmation UI against a fresh
embedded Bee base. The base artifacts are deployment content, not Hub roots:
changing a Hub dependency must never remove or replace them.
"""
from pathlib import Path
import hashlib
import sys
import tempfile

from native_workspace import NativeDesktop
from native_client import live_owners, owner_pidfd, stop_owner


binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="bee-native-modules-lifecycle-") as temporary:
    root = Path(temporary)
    project = root / "project"
    project.mkdir()
    state = root / "state"
    ui = NativeDesktop(binary, project, state, application="bee.modules:app")
    try:
        def base_hashes():
            artifacts = sorted(state.glob("base/**/vendor/bee/*.wapp"))
            return {str(path.relative_to(state)): hashlib.sha256(path.read_bytes()).hexdigest() for path in artifacts}

        def select_test():
            ui.wait("MODULES", timeout=20)
            ui.key(b"K")
            ui.wait("Keyword (empty is all): bee")
            ui.key(b"\x7f\x7f\x7f\r")
            ui.wait("Keyword: all")
            # A one-token query puts wippy/test in a deterministic third row.
            ui.key(b"/")
            ui.wait("Search: ")
            ui.key(b"test\r")
            ui.wait("Search: test")
            ui.wait("Test Framework")
            ui.key(b"\x1b[B" * 3)
            ui.key(b"\r")
            ui.wait("Test Framework")

        select_test()
        ui.wait("0.4.17")
        ui.wait("0.4.16")
        baseline = base_hashes()
        assert baseline, "native Bee base artifacts were not materialized"

        def assert_base_preserved(action):
            # The runtime may add content-addressed cache aliases after it
            # first writes a resolution. Every deployment artifact captured
            # at boot must nevertheless remain present and byte-identical.
            current = base_hashes()
            changed = {path: {"before": digest, "after": current.get(path)}
                for path, digest in baseline.items() if current.get(path) != digest}
            assert not changed, f"{action} changed or removed embedded Bee base artifacts: {changed}"

        def apply(action):
            ui.key(b"p")
            ui.wait("Ready for confirmation", timeout=10)
            assert not any("remove" in line and "bee/" in line for line in ui.text().splitlines()), \
                f"{action} plan tries to remove a bundled Bee module\n{ui.text()}"
            ui.key(b"\r")
            ui.wait("MODULES  CONFIRM")
            ui.key(b"\r")
            ui.wait("Completed", timeout=20)
            ui.wait("Receipt state: complete")
            assert_base_preserved(action)

        apply("install")
        # Reopen the selected package, choose the preceding historical version
        # and update its one Hub dependency root.
        ui.key(b"\x1b")
        ui.wait("MODULES  CATALOG")
        ui.key(b"\r")
        ui.wait("Test Framework")
        ui.key(b"\x1b[B")
        ui.key(b"u")
        apply("update")
        # Uninstall removes exactly the Hub dependency root. A second removal
        # must be rejected, proving the root is absent while the base remains.
        ui.key(b"\x1b")
        ui.wait("MODULES  CATALOG")
        ui.key(b"\r")
        ui.wait("Test Framework")
        ui.key(b"x")
        apply("uninstall")
        ui.key(b"\x1b")
        ui.wait("MODULES  CATALOG")
        ui.key(b"\r")
        ui.wait("Test Framework")
        ui.key(b"x")
        ui.key(b"p")
        ui.wait("component has no installed Hub root")
        assert_base_preserved("rejected repeated uninstall")
        # Restart the physical client against the same state, then prove the
        # removed Hub root remains absent and the base remains byte-identical.
        ui.quit()
        ui = NativeDesktop(binary, project, state, application="bee.modules:app")
        select_test()
        ui.key(b"x")
        ui.key(b"p")
        ui.wait("component has no installed Hub root")
        assert_base_preserved("restart")
    finally:
        ui.close()
        for pid in live_owners(binary, state):
            stop_owner(owner_pidfd(pid, binary, state))

print("Native Modules lifecycle: install, update and uninstall preserve Bee base modules")
