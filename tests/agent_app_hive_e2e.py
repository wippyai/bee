"""One continuous managed-agent authoring and cross-Hive application proof."""
import os
import subprocess
import time
from pathlib import Path

from workspace import ROOT, RUNTIME


def exercise():
    selected = os.environ.get("BEE_AGENT_APP_HIVE_E2E_EVIDENCE")
    evidence = Path(selected).resolve() if selected else ROOT / ".wippy/evidence" / time.strftime("agent-app-hive-e2e-%Y%m%d-%H%M%S")
    evidence.mkdir(parents=True, exist_ok=bool(selected))
    source = evidence / "source"
    authoring = os.environ.copy()
    authoring.update({"BEE_RUNTIME": str(RUNTIME), "BEE_AGENT_APP_EVIDENCE": str(source),
                      "BEE_AGENT_APP_NODE_NAME": "node-1", "BEE_AGENT_APP_SINGLE_VERSION": "1",
                      "BEE_AGENT_APP_HIVE_SOURCE_FIXTURE": "1"})
    subprocess.run(["python3", "tests/agent_app.py"], cwd=ROOT, env=authoring, check=True)

    delivery = os.environ.copy()
    delivery.update({"BEE_RUNTIME": str(RUNTIME),
                     "BEE_AGENT_APP_HIVE_ARTIFACT": str(source / "authored.json"),
                     "BEE_AGENT_APP_HIVE_SOURCE_PROJECT": str(source / "project"),
                     "BEE_AGENT_APP_HIVE_SOURCE_STATE": str(source),
                     "BEE_AGENT_APP_HIVE_EVIDENCE": str(evidence / "hive")})
    subprocess.run(["python3", "tests/agent_app_hive.py"], cwd=ROOT, env=delivery, check=True)

    # The same journey for an agent-built workspace application the
    # destination admits only through its own shipped rule and person.
    workspace = os.environ.copy()
    workspace.update({"BEE_RUNTIME": str(RUNTIME), "BEE_WORKSPACE_APP_HIVE_EVIDENCE": str(evidence / "workspace")})
    subprocess.run(["python3", "tests/workspace_app_hive.py"], cwd=ROOT, env=workspace, check=True)
    print("Continuous Agent App Hive: the managed authoring Bee published its locally reviewed application across Hive, "
          "and an agent-built workspace application opened on a second node after that node's own approval; evidence in "
          + str(evidence))


if __name__ == "__main__":
    exercise()
