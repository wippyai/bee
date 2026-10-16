#!/usr/bin/env python3
"""Write wippy.build.local.json: wippy.build.json pinned to local commits.

Arguments: the local runtime checkout and this repository. The runtime is
pinned to its checkout's HEAD commit and the native host to this repository's
HEAD, resolved by Go to its module version through the same scoped git URL
rewrites the build uses. The application pack this build writes keeps the digest
its local pack recorded. The file is rewritten only when its content changes,
so make does not rebuild the toolchain for an unchanged pin.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

NATIVE = "github.com/wippyai/bee/native"
BUILT = "dist/"


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


def pinned(release, local, runtime_version, native_version):
    """The release manifest pinned to local commits. The application pack this
    build produces keeps the digest its last local pack recorded; every other
    input comes from the release manifest."""
    manifest = json.loads(json.dumps(release))
    manifest["runtime"]["version"] = runtime_version
    for native in manifest.get("native", []):
        if native["module"] == NATIVE:
            native["version"] = native_version
    built = {(pack["module"], pack["path"]): pack["sha256"]
             for pack in (local or {}).get("application", {}).get("packs", []) if pack["path"].startswith(BUILT)}
    for pack in manifest.get("application", {}).get("packs", []):
        recorded = built.get((pack["module"], pack["path"]))
        if recorded:
            pack["sha256"] = recorded
    return manifest


def main(runtime, repository):
    runtime, repository = os.path.abspath(runtime), os.path.abspath(repository)
    local = Path("wippy.build.local.json")
    previous = json.loads(local.read_text()) if local.exists() else None
    manifest = pinned(json.loads(Path("wippy.build.json").read_text()), previous, head(runtime),
                      module_version(NATIVE, head(repository), runtime, repository))
    content = json.dumps(manifest, indent=2) + "\n"
    if not local.exists() or local.read_text() != content:
        local.write_text(content)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
