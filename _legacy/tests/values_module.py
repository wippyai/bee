"""Pack and exercise bee/values in a composition with no Bee service packages."""
from pathlib import Path
import os
import subprocess
import tempfile

from workspace import ROOT, RUNTIME, stage_values


def run(folder, *arguments, env=None):
    result = subprocess.run([str(RUNTIME), *arguments], cwd=folder,
                            env={**os.environ, "TMPDIR": str(ROOT / ".wippy/tmp"), **(env or {})},
                            capture_output=True, text=True, timeout=90)
    output = result.stdout + result.stderr
    if result.returncode != 0:
        raise AssertionError(output)
    return output


def main():
    temporary_root = ROOT / ".wippy/tmp"
    temporary_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bee-values-module-", dir=temporary_root) as directory:
        folder = Path(directory)
        stage_values(folder)
        source = folder / "src"
        source.mkdir()
        (source / "_index.yaml").write_text("""version: '1.0'
namespace: bee
entries:
- name: dependency_values
  kind: ns.dependency
  component: bee/values
  version: 0.1.0-dev
- name: terminal
  kind: terminal.host
  lifecycle: {auto_start: true}
""")
        check = source / "values/check"
        check.mkdir(parents=True)
        (check / "_index.yaml").write_text("""version: '1.0'
namespace: bee.values.check
entries:
- name: probe
  kind: process.lua
  source: file://probe.lua
  method: main
  modules: [process, hash]
  imports:
    bounds: bee.values:bounds
    canonical: bee.values:canonical
    clock: bee.values:clock
    reply: bee.values:reply
""")
        (check / "probe.lua").write_text("""local bounds = require("bounds")
local canonical = require("canonical")
local clock = require("clock")
local reply = require("reply")
local hash = require("hash")

local function main()
    if bounds.id("isolated") ~= "isolated" then error("bounds probe failed") end
    local encoded = assert(canonical.encode({b = 2, a = 1}))
    if encoded ~= '{"a":1,"b":2}' then error("canonical probe failed") end
    if assert(hash.sha256(encoded)) ~= "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777" then
        error("digest probe failed")
    end
    if not bounds.timestamp(clock.now()) then error("time probe failed") end
    local decoded = assert(reply.decode({ok = true, value = "ready"}))
    if decoded.ok ~= true or decoded.value ~= "ready" then error("reply probe failed") end
end

return {main = main}
""")
        (folder / "wippy.lock").write_text("""directories:
  modules: .wippy
  src: ./src
modules:
- name: bee/values
  version: 0.1.0-dev
""")
        (folder / ".wippy.yaml").write_text("""version: '1.0'
shutdown:
  timeout: 2s
workspace:
  replacements:
    bee/values: ./modules/values
""")

        run(folder, "lint", "--strict-any", "--set", "lua.type_system.enabled=true",
            "--set", "lua.type_system.strict=true", "--set", "lua.type_system.strict_any=true")
        pack = folder / "values.wapp"
        run(folder, "pack", "--module", "bee/values", str(pack))
        assert pack.is_file() and pack.stat().st_size > 0, "values module pack was not created"
        run(folder, "run", "-x", "bee.values.check:probe")
    print("Values module: isolated strict lint, module-only pack, bounds/canonical/time/reply probe")


if __name__ == "__main__":
    main()
