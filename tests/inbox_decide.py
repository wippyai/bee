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
from workspace import ROOT, RUNTIME, database_environment  # noqa: E402

WORKSPACE = "0123456789abcdef0123456789abcdef"
POLICY = "inbox-decide"
PROMPT = "Apply demo decide version v1"


def edit_approver_policy(project):
    index = project / "src/approvals/_index.yaml"
    import yaml
    doc = yaml.safe_load(index.read_text())
    entry = next(e for e in doc["entries"] if e["name"] == "approver_policies")
    entry["policies"].append(
        {"name": POLICY, "approvers": ["bee.local"], "max_ttl_ms": 600000})
    index.write_text(yaml.safe_dump(doc, sort_keys=False))


def edit_inbox_workspaces(project):
    index = project / "src/apps/inbox/_index.yaml"
    import yaml
    doc = yaml.safe_load(index.read_text())
    entry = next(e for e in doc["entries"] if e["name"] == "workspaces")
    entry["data"]["workspaces"].append(WORKSPACE)
    index.write_text(yaml.safe_dump(doc, sort_keys=False))


def run_probe(project, folder, command, timeout):
    args = [str(RUNTIME), "run", "--verbose", command, "--host", "bee:workers",
            "--set", f"registry.history_path={folder}/registry.db"]
    result = subprocess.run(args, cwd=project, capture_output=True, text=True,
                            timeout=timeout, env=database_environment(folder))
    return result


def exercise():
    with tempfile.TemporaryDirectory(prefix="bee-inbox-decide-") as directory:
        folder = Path(directory)
        project = folder / "project"
        shutil.copytree(ROOT / "src", project / "src")
        shutil.copytree(ROOT / "tests/fixtures/inbox_decide", project / "src/probe")
        for name in [".wippy.yaml", "wippy.lock", "wippy.yaml"]:
            shutil.copy2(ROOT / name, project / name)
        edit_approver_policy(project)
        edit_inbox_workspaces(project)
        subprocess.run([str(RUNTIME), "lint"], cwd=project, check=True, timeout=120)
        seeded = run_probe(project, folder, "inbox-decide-seed", 120)
        assert seeded.returncode == 0 and "INBOX_DECIDE_SEEDED" in seeded.stdout + seeded.stderr, \
            seeded.stdout + seeded.stderr
        match = re.search(r'"plan_digest": "([0-9a-f]{64})".*"proposal_digest": "([0-9a-f]{64})',
                          seeded.stdout + seeded.stderr)
        assert match, seeded.stdout + seeded.stderr
        plan_digest, proposal_digest = match.group(1), match.group(2)
        ui = Desktop(folder, project=project, apps=("bee.inbox:app",))
        try:
            ui.wait("APPROVALS", timeout=30)
            ui.wait("bee.governance:apply", timeout=30)
            ui.key(b"j")
            ui.key(b"o")
            ui.wait("Asked: " + PROMPT, timeout=20)
            ui.key(b"a")
            ui.wait("Approve this request?", timeout=20)
            ui.key(b"\t")
            ui.key(b"\r")
            ui.wait("approved by bee.local", timeout=30)
            ui.key(b"\x1b")
            ui.pump(.5)
            ui.quit()
        finally:
            ui.close()
        consumed = run_probe(project, folder, "inbox-decide-consume", 120)
        output = consumed.stdout + consumed.stderr
        assert consumed.returncode == 0 and "INBOX_DECIDE_CONSUMED" in output, output
        assert "INBOX_DECIDE_SECOND_REFUSED" in output, output
        assert plan_digest in output and proposal_digest in output, output
    print("Inbox decide: staged plan decided through the inbox UI, consumption binds "
          "the exact plan digest, second effect refused")


if __name__ == "__main__":
    exercise()
