"""Real Claude and Codex startup through the managed broker PTY.

The fixture proves the bounded window lifecycle only.  It deliberately never
submits a provider turn or enables a production permission exchange.
"""
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
codex_selected = os.environ.get("BEE_CODEX_BIN")
if not codex_selected:
    raise SystemExit("BEE_CODEX_BIN must name the actual Codex executable")
binary = Path(selected).resolve(strict=True)
codex_binary = Path(codex_selected).resolve(strict=True)
claude_version = subprocess.check_output([str(binary), "--version"], text=True, timeout=15).strip()
codex_version = subprocess.check_output([str(codex_binary), "--version"], text=True, timeout=15).strip()
claude_declared = yaml.safe_load((ROOT / "modules/driver-claude/src/_index.yaml").read_text())
codex_declared = yaml.safe_load((ROOT / "modules/driver-codex/src/_index.yaml").read_text())
claude_profile_version = next(e for e in claude_declared["entries"] if e["name"] == "profiles")["data"]["driver"]["implementation_version"]
codex_profile_version = next(e for e in codex_declared["entries"] if e["name"] == "profiles")["data"]["driver"]["implementation_version"]
print(f"Actual Claude under test: {claude_version}; declaration version: {claude_profile_version}", flush=True)
print(f"Actual Codex under test: {codex_version}; declaration version: {codex_profile_version}", flush=True)
with socket.socket() as endpoint, fixture_workspace(unit_tests=False) as folder:
    endpoint.bind(("127.0.0.1", 0))
    shutil.copytree(ROOT / "tests/fixtures/managed_provider_window", folder / "src/tests/managed_provider_window")
    path = folder / "src/tests/managed_provider_window/_index.yaml"
    document = yaml.safe_load(path.read_text())
    claude_policy = next(e for e in document["entries"] if e["name"] == "policy_claude")["data"]
    claude_policy["executables"] = {"claude": str(binary)}
    claude_policy["environment"] = {"ANTHROPIC_BASE_URL": f"http://127.0.0.1:{endpoint.getsockname()[1]}", "DISABLE_AUTOUPDATER": "1"}
    codex_policy = next(e for e in document["entries"] if e["name"] == "policy_codex")["data"]
    codex_policy["executables"] = {"codex": str(codex_binary)}
    codex_policy["environment"] = {"DISABLE_AUTOUPDATER": "1"}
    provider = next(e for e in document["entries"] if e["name"] == "codex_provider")["data"]
    provider["base_url"] = f"http://127.0.0.1:{endpoint.getsockname()[1]}/v1"
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
    assert len(rows) == 2, "provider startup must create one attempt per provider"
    by_executable = {json.loads(request)["launch"]["executable"]: (json.loads(request), home_key, exit_source, cleanup)
                     for request, home_key, exit_source, cleanup in rows}
    assert str(binary) in by_executable and str(codex_binary) in by_executable, "both bound provider executables must be attempted"
    claude_request, claude_home_key, claude_exit, claude_cleanup = by_executable[str(binary)]
    codex_request, codex_home_key, codex_exit, codex_cleanup = by_executable[str(codex_binary)]
    assert claude_request["launch"]["argv"] == ["--permission-mode", "default"], "Claude startup injected a prompt or duplicate executable"
    assert codex_request["launch"]["argv"] == ["--sandbox", "read-only"], "Codex startup injected a prompt or duplicate executable"
    assert claude_exit == "terminal" and claude_cleanup == "pending", "Claude PTY completion overstated cleanup evidence"
    assert codex_exit == "terminal" and codex_cleanup == "pending", "Codex PTY completion overstated cleanup evidence"
    assert claude_home_key != codex_home_key, "provider attempts must have distinct private homes"
    claude_home = placement_root / "attempts" / claude_home_key / "home"
    codex_home = placement_root / "attempts" / codex_home_key / "home"
    assert claude_home.is_dir() and any(claude_home.iterdir()), "Claude did not initialize its private home"
    assert codex_home.is_dir() and any(codex_home.iterdir()), "Codex did not initialize its private home"
    assert not (claude_home / ".claude" / ".credentials.json").exists(), "Claude startup unexpectedly acquired credentials"
    codex_config = codex_home / ".codex" / "config.toml"
    assert codex_config.is_file(), "Codex provider configuration was not materialized"
    config_text = codex_config.read_text()
    assert config_text.startswith("# generated by bee bee.codex-config@1"), "Codex configuration was not host-generated"
    assert provider["base_url"] in config_text and "env_key = \"OPENAI_API_KEY\"" in config_text, "Codex provider configuration was incomplete"
    assert not (codex_home / ".codex" / "auth.json").exists(), "Codex startup unexpectedly acquired credentials"
print("Real provider startup: Claude and Codex broker PTY frames, keyboard response, resize, rebind and cancellation passed; fixture cleanup policy only; no authenticated turn or production cleanup proven")
