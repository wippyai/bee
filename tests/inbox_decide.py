"""Decide a staged governance plan through the inbox the way a person would.

Seeds one reviewed-selected plan in the governance plan store and one
approval request on its exact proposal, opens the inbox under the broker,
selects and approves the request with the same keys a person presses, then
consumes the decision headlessly: the consumption receipt binds the exact
plan digest and a second effect is refused.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tui_smoke import Desktop  # noqa: E402
from workspace import ROOT, RUNTIME, database_environment, pack_fixture  # noqa: E402

WORKSPACE = "0123456789abcdef0123456789abcdef"
POLICY = "inbox-decide"
PROMPT = "Apply demo decide version v1"


def edit_approver_policy(project):
    index = project / "src/approvals/host/_index.yaml"
    import yaml
    doc = yaml.safe_load(index.read_text())
    entry = next(e for e in doc["entries"] if e["name"] == "approver_policies")
    entry["policies"].append(
        {"name": POLICY, "approvers": [{"definition_id": "bee.inbox:app"}], "max_ttl_ms": 600000})
    index.write_text(yaml.safe_dump(doc, sort_keys=False))


def edit_inbox_workspaces(project):
    index = project / "src/apps/inbox/_index.yaml"
    import yaml
    doc = yaml.safe_load(index.read_text())
    entry = next(e for e in doc["entries"] if e["name"] == "workspaces")
    entry["data"]["workspaces"].append(WORKSPACE)
    index.write_text(yaml.safe_dump(doc, sort_keys=False))


def run_probe(project, folder, command, timeout, pack_file=None):
    args = [str(RUNTIME), "run", "--verbose"]
    if pack_file:
        args.append(str(pack_file))
    args += [command, "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=folder if pack_file else project, capture_output=True, text=True,
                            timeout=timeout, env=database_environment(folder))
    return result


def exercise(packed):
    with tempfile.TemporaryDirectory(prefix="bee-inbox-decide-") as directory:
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "modules", project / "modules")
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/inbox_decide", project / "src/probe")
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        edit_approver_policy(project)
        edit_inbox_workspaces(project)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True, timeout=120)
        pack = folder / "bee.wapp"
        if packed:
            pack_fixture(project, pack)
        launch_pack = pack if packed else None
        seeded = run_probe(project, folder, "inbox-decide-seed", 120, launch_pack)
        assert seeded.returncode == 0 and "INBOX_DECIDE_SEEDED" in seeded.stdout + seeded.stderr, \
            seeded.stdout + seeded.stderr
        seeded_output = seeded.stdout + seeded.stderr
        plan_match = re.search(r'"plan_digest": "([0-9a-f]{64})"', seeded_output)
        proposal_match = re.search(r'"proposal_digest": "([0-9a-f]{64})"', seeded_output)
        assert plan_match and proposal_match, seeded_output
        plan_digest, proposal_digest = plan_match.group(1), proposal_match.group(1)
        # Exercise the user path through Start so the broker creates the
        # private application actor and selects the host-admitted definition.
        ui = Desktop(folder, packed=packed, project=project, pack_file=pack)
        try:
            ui.wait("No applications open", timeout=30)
            ui.open_start()
            ui.choose("Tools")
            ui.choose("Approvals")
            ui.wait("APPROVALS", timeout=30)
            ui.wait("bee.governance:apply", timeout=30)
            ui.key(b"j")
            ui.key(b"o")
            ui.wait("Asked: " + PROMPT, timeout=20)
            ui.key(b"a")
            ui.wait("Approve this request?", timeout=20)
            ui.key(b"\t")
            ui.key(b"\r")
            # The broker owns the application principal.  The exact instance
            # suffix is host generated, so the frame must show that actor
            # family rather than a registry or request supplied identity.
            ui.wait("approved by bee.application:", timeout=30)
            ui.key(b"\x1b")
            ui.pump(.5)
            ui.quit()
        finally:
            ui.close()
        consumed = run_probe(project, folder, "inbox-decide-consume", 120, launch_pack)
        output = consumed.stdout + consumed.stderr
        assert consumed.returncode == 0 and "INBOX_DECIDE_CONSUMED" in output, output
        assert "INBOX_DECIDE_SECOND_REFUSED" in output, output
        assert plan_digest in output and proposal_digest in output, output
        decider = re.search(r'"decider_id": "(bee\.application:[0-9a-f]+:[^"]+)"', output)
        assert decider, output
    print("Inbox decide " + ("packed" if packed else "source") + ": staged plan decided "
          "through Start, consumption binds the exact plan digest, second effect refused")


if __name__ == "__main__":
    exercise(False)
    exercise(True)
