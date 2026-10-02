"""Prove machine login links using a local runtime PR build via BEE_RUNTIME."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

import yaml

from fixture_lint import environment
from workspace import RUNTIME, ROOT, fixture_workspace


def main():
    assert os.environ.get("BEE_RUNTIME"), "Set BEE_RUNTIME to the proof-only runtime build"
    cases = ("contained",) if "--contained-pin" in sys.argv else ("accepted", "refused-target", "refused-parent")
    for case in cases:
        with fixture_workspace(managed_gateway=True) as folder:
            home = folder / "login-home"
            store = folder / "login-store"
            (home / ".codex").mkdir(parents=True, mode=0o700)
            store.mkdir(mode=0o700)
            target = store / "fixture.json"
            target.write_text('{"fixture":true}')
            target.chmod(0o600 if case != "refused-target" else 0o620)
            if case == "refused-parent":
                store.chmod(0o720)
            (home / ".codex/auth.json").symlink_to(target)
            probe = folder / "src/tests/loginlinks"
            probe.mkdir()
            shutil.copy2(ROOT / "tests/fixtures/login_links/probe.lua", probe / "probe.lua")
            entries = [
                {"name": "facts", "kind": "env.storage.static", "data": {"values": {"expected": case, "target": str(store if case == "refused-parent" else target)}}},
                *[{"name": name, "kind": "env.variable", "storage": "bee.test.loginlinks:facts", "variable": name, "readonly": True} for name in ("expected", "target")],
                {"name": "probe", "kind": "function.lua", "source": "file://probe.lua", "method": "run", "meta": {"type": "test", "suite": "bee"},
                 "modules": ["funcs", "security", "registry", "env", "fs"],
                 "security": {"policies": ["bee.harness.security:launch_locate_probe_policy", "bee.credentials.security:credential_file_policy",
                                            "bee.test.loginlinks:probe_policy"]},
                 "imports": {"test": "wippy.test:test", "bounds": "bee.protocol:bounds", "principals": "bee.test.principals:bound",
                             "locator": "bee.harness.launch:locate", "agents": "bee.harness.app:agents",
                             "sessions": "bee.app:sessions", "sessions_fixtures": "bee.tests.sessions:fixtures"}},
                {"name": "probe_policy", "kind": "security.policy", "policy": {"actions": ["env.get"], "resources": ["bee.test.loginlinks:expected", "bee.test.loginlinks:target"], "effect": "allow"}},
            ]
            # The proof explicitly copies only the production machine source's
            # selected policy. No other directory gains external-link reads.
            index = folder / "src/env/_index.yaml"
            document = yaml.safe_load(index.read_text())
            source = next(entry for entry in document["entries"] if entry["name"] == "machine_login_source")
            source["link_policy"] = "owner_safe"
            index.write_text(yaml.safe_dump(document, sort_keys=False))
            host_index = folder / "src/tests/harness/host/_index.yaml"
            host = yaml.safe_load(host_index.read_text())
            executable = folder / "fixtures/harness/bin/codex-loginlinks"
            executable.write_text('#!/bin/sh\nif [ "$1" = "--version" ]; then echo "codex-cli 1.2.3"; exit 0; fi\nexit 1\n')
            executable.chmod(0o700)
            host["entries"][0]["data"]["values"]["codex"] = str(executable)
            host_index.write_text(yaml.safe_dump(host, sort_keys=False))
            (probe / "_index.yaml").write_text(yaml.safe_dump({"version": "1.0", "namespace": "bee.test.loginlinks", "entries": entries}, sort_keys=False))
            selected = "bee.test.loginlinks:probe"
            for manifest in (folder / "src/tests").rglob("_index.yaml"):
                document = yaml.safe_load(manifest.read_text())
                for entry in document.get("entries", []):
                    if entry.get("meta", {}).get("type") == "test" and f'{document["namespace"]}:{entry["name"]}' != selected:
                        entry["meta"]["type"] = "test_support"
                manifest.write_text(yaml.safe_dump(document, sort_keys=False))
            variables = environment(folder)
            variables.update({"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share")})
            subprocess.run([str(RUNTIME), "lint", "--ns", "bee.test.loginlinks", "--strict-any", "--set", "lua.type_system.enabled=true", "--set", "lua.type_system.strict=true"],
                           cwd=folder, env=variables, check=True, timeout=300)
            subprocess.run([str(RUNTIME), "test", "--host", "bee:terminal", "test", selected], cwd=folder, env=variables, check=True, timeout=300)
            print(f"login links {case}: pass", flush=True)


if __name__ == "__main__":
    main()
