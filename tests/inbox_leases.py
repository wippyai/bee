"""Batch decide, the lease form and the active leases view through the real
inbox under the broker.

Seeds two pending requests of one requester, one pending activation request
and one active lease, opens the inbox through Start, marks and decides the two
requests as one batch, opens the lease form, submits it to the real
governance owner and revokes the seeded lease from the leases view."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, database_environment  # noqa: E402

WORKSPACE = "0123456789abcdef0123456789abcdef"
POLICY = "inbox-leases"


def edit_project(project):
    import yaml
    index = project / "src/_index.yaml"
    doc = yaml.safe_load(index.read_text())
    entry = next(e for e in doc["entries"] if e["name"] == "approver_policies")
    entry["policies"].append(
        {"name": POLICY, "approvers": [{"definition_id": "bee.approvals.inbox:app"}], "max_ttl_ms": 600000})
    index.write_text(yaml.safe_dump(doc, sort_keys=False))
    inbox = project / "modules/approvals-inbox/src/_index.yaml"
    doc = yaml.safe_load(inbox.read_text())
    entry = next(e for e in doc["entries"] if e["name"] == "workspaces")
    entry["data"]["workspaces"].append(WORKSPACE)
    inbox.write_text(yaml.safe_dump(doc, sort_keys=False))


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-inbox-leases-") as directory:
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "modules", project / "modules")
        shutil.copytree(ROOT / "tests/fixtures/inbox_leases", project / "src/probe")
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        edit_project(project)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True, timeout=120)
        seeded = subprocess.run([str(RUNTIME), "run", "--verbose", "inbox-leases-seed", "--host", "bee:workers",
                                 "--set", f"registry.history_path={folder}/registry.db"], cwd=project,
                                capture_output=True, text=True, timeout=120, env=database_environment(folder))
        assert seeded.returncode == 0 and "INBOX_LEASES_SEEDED" in seeded.stdout + seeded.stderr, \
            seeded.stdout + seeded.stderr
        ui = Desktop(folder, packed=False, project=project, deployment=None)
        try:
            ui.wait("No applications open", timeout=30)
            ui.open_start()
            ui.choose("Tools")
            ui.choose("Approvals")
            ui.wait("APPROVALS", timeout=30)
            ui.wait("3 pending", timeout=30)
            # Rows list newest first: activation, second, first. Mark the two ordinary ones.
            ui.key(b"j")
            ui.key(b"o")
            ui.pump(.5)
            ui.key(b"m")
            ui.key(b"j")
            ui.key(b"o")
            ui.pump(.5)
            ui.key(b"m")
            ui.wait("[x]", timeout=10)
            ui.key(b"b")
            ui.wait("Approve 2 requests?", timeout=20)
            ui.key(b"\t")
            ui.key(b"\r")
            ui.wait("Decided 2 requests", timeout=30)
            # The activation request: open the lease form, submit it to governance.
            ui.key(b"k")
            ui.key(b"k")
            ui.key(b"o")
            ui.wait("bee.gov:establish-overlay", timeout=20)
            ui.key(b"l")
            ui.wait("LEASE REQUEST", timeout=20)
            ui.wait("Max applies", timeout=10)
            ui.key(b"\x13")
            ui.pump(1.5)
            outcome = ui.text()
            # No installed application backs this seeded request: governance refuses it honestly.
            assert "BLOCKED" in outcome or "Lease request filed" in outcome, outcome
            # The leases view lists the seeded lease with usage and revokes it.
            ui.key(b"v")
            ui.wait("LEASES", timeout=20)
            ui.wait("used 1/5", timeout=20)
            ui.key(b"j")
            ui.key(b"x")
            ui.wait("Revoke this lease?", timeout=20)
            ui.key(b"\t")
            ui.key(b"\r")
            ui.wait("Lease revoked", timeout=30)
            ui.wait("revoked", timeout=20)
            ui.key(b"\x1b")
            ui.pump(.5)
            ui.quit()
        finally:
            ui.close()
    print("Inbox leases: batch decided as one, lease form submitted to governance, seeded lease listed and revoked")


if __name__ == "__main__":
    exercise()
