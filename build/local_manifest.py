#!/usr/bin/env python3
"""Write wippy.build.local.json: wippy.build.json pinned to local commits.

Arguments: the local runtime checkout and this repository. The runtime is
pinned to its checkout's HEAD commit and the native host to this repository's
HEAD, resolved by Go to its module version through the same scoped git URL
rewrites the build uses. The file is rewritten only when its content changes,
so make does not rebuild the toolchain for an unchanged pin.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

NATIVE = "github.com/wippyai/bee/native"


def head(repository):
    return subprocess.run(["git", "-C", repository, "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()


def module_version(module, commit, runtime, repository):
    env = dict(os.environ, GOWORK="off", GOPROXY="direct", GOFLAGS="-mod=mod",
               GONOSUMDB="github.com/wippyai/runtime,github.com/wippyai/bee",
               GOPRIVATE="github.com/wippyai/runtime,github.com/wippyai/bee",
               GIT_CONFIG_COUNT="2",
               GIT_CONFIG_KEY_0=f"url.file://{runtime}.insteadOf", GIT_CONFIG_VALUE_0="https://github.com/wippyai/runtime",
               GIT_CONFIG_KEY_1=f"url.file://{repository}.insteadOf", GIT_CONFIG_VALUE_1="https://github.com/wippyai/bee")
    out = subprocess.run(["go", "list", "-m", "-json", f"{module}@{commit}"], capture_output=True, text=True,
                         check=True, env=env, cwd=repository).stdout
    return json.loads(out)["Version"]


def main(runtime, repository):
    runtime, repository = os.path.abspath(runtime), os.path.abspath(repository)
    manifest = json.loads(Path("wippy.build.json").read_text())
    manifest["runtime"]["version"] = head(runtime)
    native_version = module_version(NATIVE, head(repository), runtime, repository)
    for native in manifest.get("native", []):
        if native["module"] == NATIVE:
            native["version"] = native_version
    local = Path("wippy.build.local.json")
    content = json.dumps(manifest, indent=2) + "\n"
    if not local.exists() or local.read_text() != content:
        local.write_text(content)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
