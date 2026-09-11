"""Real Claude startup through the managed broker PTY, with no credentials/prompt."""
import os
import json
import sqlite3
from pathlib import Path
import shutil
import socket
import subprocess
import yaml
from workspace import RUNTIME, fixture_workspace, database_environment

ROOT = Path(__file__).resolve().parents[1]
selected = os.environ.get("BEE_CLAUDE_BIN")
if not selected:
    raise SystemExit("BEE_CLAUDE_BIN must name the actual Claude executable")
binary = Path(selected).resolve(strict=True)
version = subprocess.check_output([str(binary), "--version"], text=True, timeout=15).strip()
declared = yaml.safe_load((ROOT / "src/driver/claude/_index.yaml").read_text())
profile_version = next(e for e in declared["entries"] if e["name"] == "profiles")["data"]["driver"]["implementation_version"]
print(f"Actual provider under test: {version}; declaration version: {profile_version}", flush=True)
with socket.socket() as endpoint, fixture_workspace(unit_tests=False) as folder:
    endpoint.bind(("127.0.0.1", 0))
    shutil.copytree(ROOT / "tests/fixtures/managed_provider_window", folder / "src/tests/managed_provider_window")
    path = folder / "src/tests/managed_provider_window/_index.yaml"
    document = yaml.safe_load(path.read_text())
    policy = next(e for e in document["entries"] if e["name"] == "policy")["data"]
    policy["executables"] = {"claude": str(binary)}
    policy["environment"] = {"ANTHROPIC_BASE_URL": f"http://127.0.0.1:{endpoint.getsockname()[1]}", "DISABLE_AUTOUPDATER": "1"}
    path.write_text(yaml.safe_dump(document, sort_keys=False))
    placement_root = folder / "placement-root"
    placement_root.mkdir(mode=0o700)
    environment = database_environment(folder, BEE_PLACEMENT_ROOT=str(placement_root))
    for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CLAUDE_CONFIG_DIR", "CODEX_HOME"):
        environment.pop(key, None)
    subprocess.run([str(RUNTIME), "lint"], cwd=folder, env=environment, check=True, timeout=90)
    subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal"], cwd=folder, env=environment, check=True, timeout=60)
    with sqlite3.connect(folder / "placement.db") as db:
        rows = db.execute("SELECT request_json, home_key, exit_source, cleanup_state FROM bee_placement_attempts").fetchall()
    assert len(rows) == 1, "provider startup must create one attempt"
    request, home_key, exit_source, cleanup = rows[0]
    launch = json.loads(request)["launch"]
    assert launch["argv"] == ["--permission-mode", "default"], "empty startup injected a prompt or duplicate executable"
    assert exit_source == "terminal" and cleanup == "pending", "PTY completion overstated cleanup evidence"
    private_home = placement_root / "attempts" / home_key / "home"
    assert private_home.is_dir() and any(private_home.iterdir()), "provider did not initialize its private home"
    assert not (private_home / ".claude" / ".credentials.json").exists(), "startup unexpectedly acquired credentials"
print("Real provider startup: broker PTY frames, keyboard response, resize, rebind and cancellation passed; fixture cleanup policy only; no authenticated turn or production cleanup proven")
