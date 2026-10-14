"""Offline installed-CLI compatibility checks; no login, provider call, or personal config."""
import argparse
import json
import pathlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests/fixtures/driver-options"


def toml_value(value):
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k) + "=" + toml_value(v) for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ",".join(toml_value(v) for v in value) + "]"
    return json.dumps(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", choices=("claude", "codex"), action="append")
    args = parser.parse_args()
    cases = json.loads((FIXTURES / "coverage.json").read_text())
    scratch = ROOT / ".wippy/driver-option-compat"
    scratch.mkdir(parents=True, exist_ok=True)
    temp = scratch / "scratch"
    temp.mkdir(exist_ok=True)
    env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(scratch), "CODEX_HOME": str(scratch),
           "CLAUDE_CONFIG_DIR": str(scratch / "claude"), "TMPDIR": str(temp)}
    (scratch / "fixture.txt").write_text("Fixture instructions\n")
    (scratch / "fixture.toml").write_text('model = "fixture"\n')
    help_cache = {}
    checked = 0
    for driver in args.driver or ("claude", "codex"):
        executable = shutil.which(driver)
        assert executable, f"{driver} is not installed"

        def run(argv, input_text=None):
            return subprocess.run([executable, *argv], env=env, cwd=scratch, input=input_text,
                                  capture_output=True, text=True, timeout=30)

        version = run(["--version"])
        expected_version = next(c["version"] for c in cases if c["driver"] == driver)
        observed_version = re.search(r"\b[0-9]+\.[0-9]+\.[0-9]+\b", version.stdout)
        assert observed_version and observed_version.group() == expected_version, f"Version fixture needed for {driver}: {version.stdout.strip()}"

        def config_probe(path, value):
            config = ".".join(json.dumps(k) for k in path) + "=" + toml_value(value) + "\n"
            (scratch / "config.toml").write_text(config)
            return run(["app-server", "--strict-config", "--listen", "stdio://"], "")

        if driver == "codex":
            control = config_probe(["bee_invented_option"], True)
            assert control.returncode != 0 and "unknown configuration field" in control.stderr
        for case in (c for c in cases if c["driver"] == driver):
            if "flag" in case:
                for context in case["contexts"]:
                    help_args = () if driver == "claude" or context == "window" else ("exec",) if context == "first_turn" else ("exec", "resume")
                    if help_args not in help_cache:
                        observed = run([*help_args, "--help"])
                        assert observed.returncode == 0
                        help_cache[help_args] = observed.stdout
                    assert case["flag"] in help_cache[help_args], f"{driver}.{case['id']} lacks {context} help evidence"
                    if driver == "claude" and case["id"] == "chrome":
                        assert "--no-chrome" in help_cache[help_args]
            else:
                schema = case["schema"]
                values = schema.get("enum", [case["value"]])
                for value in values:
                    observed = config_probe(case["config_path"], value)
                    assert observed.returncode == 0, f"{driver}.{case['id']} rejected: {observed.stderr[-1000:]}"
                invalid = "bee-invalid-type" if schema["type"] != "string" else {"invalid": True}
                refused = config_probe(case["config_path"], invalid)
                assert refused.returncode != 0, f"{driver}.{case['id']} ignores its declared type"
            checked += 1
        help_cache.clear()
        print(f"PASS: {driver} {expected_version}; {sum(c['driver'] == driver for c in cases)} native option mappings")
    print(f"PASS: {checked} versioned mappings; strict-config negative controls; isolated homes")


if __name__ == "__main__":
    main()
