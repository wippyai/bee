"""Post-publication check: a real Hub install into the published release deployment.

Usage: hub_release_install.py DEPLOYMENT VERSION

The deployment is the release's `bee-deployment.tar.gz`, extracted. Its lock
pins every bee/* module at VERSION as a sealed pack, so installing a Hub
package into it re-resolves each locked module online. That holds only after
the release's own packs are on the Hub, which is why this runs after
publication rather than in `make check`.
"""
import sys
from pathlib import Path
import yaml

from modules_app import exercise_real_facade
from workspace import ROOT


def release_deployment(path, version):
    deployment = Path(path).resolve()
    lock = deployment / "wippy.lock"
    if not lock.is_file():
        raise SystemExit(f"hub release install: no release deployment at {deployment}; extract the release's bee-deployment.tar.gz there")
    modules = yaml.safe_load(lock.read_text()).get("modules") or []
    versions = {module["name"]: module["version"] for module in modules if module["name"].startswith("bee/")}
    if "bee/bee" not in versions:
        raise SystemExit(f"hub release install: {lock} does not lock bee/bee; it is not a Bee release deployment")
    stray = sorted(f"{name}@{locked}" for name, locked in versions.items() if locked != version)
    if stray:
        raise SystemExit(f"hub release install: {lock} is not the {version} release; it locks {', '.join(stray)}")
    return deployment


def main(arguments):
    if len(arguments) != 2 or not arguments[0] or not arguments[1]:
        raise SystemExit("hub release install: usage: hub_release_install.py DEPLOYMENT VERSION")
    version = arguments[1].removeprefix("v")
    deployment = release_deployment(arguments[0], version)
    exercise_real_facade(ROOT, True, deployment)
    print(f"Hub release install: a real Hub package installs into the {version} release deployment, "
          "resolving every locked bee/* module from the Hub at its locked digest")


if __name__ == "__main__":
    main(sys.argv[1:])
