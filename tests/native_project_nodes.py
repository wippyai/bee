"""Project-node executable acceptance; does not claim Hive convergence."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile

from native_client import owner_handle, stop_owner
from native_workspace import NativeDesktop, STATE_ENVIRONMENT


def run(binary):
    provenance = json.loads(Path(str(binary) + ".provenance.json").read_text())
    bindings = provenance["manifest"]["application"]["data_env"]
    databases = [path for name, path in bindings.items() if name.endswith("_DB")]
    databases += [bindings["BEE_WORKSPACE_DB"] + ".client", "registry.db"]
    def check_stores(state):
        for relative in databases:
            path = state / relative
            assert path.is_file(), f"missing state-bound database: {path}"
            assert path.read_bytes()[:16] == b"SQLite format 3\0", f"not a SQLite database: {path}"
        assert (state / bindings["BEE_PLACEMENT_ROOT"]).is_dir(), "placement root escaped state"
    with tempfile.TemporaryDirectory(prefix="bee-project-nodes-") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        folders = [root / name for name in ("alpha", "beta", "empty")]
        for folder in folders:
            folder.mkdir()
        states = [home / ".config/bee/projects" / hashlib.sha256(str(folder.resolve()).encode()).hexdigest() for folder in folders]
        views, owners = [], []
        try:
            for index in range(2):
                view = NativeDesktop(binary, folders[index], None, arguments=("terminal",), home=home)
                views.append(view)
                view.wait(" BEE ", timeout=30)
                owners.append(owner_handle(view, binary, states[index]))
                view.wait("Terminal", timeout=10)
                view.key(("test \"$PWD\" = " + shlex.quote(str(folders[index])) +
                          f" && printf 'PROJECT_{index}_%s\\n' CORRECT\r").encode())
                view.wait(f"PROJECT_{index}_CORRECT", timeout=10)
                assert b"Starting Bee" in view.raw, "different project reused an existing node"
            for state in states[:2]:
                check_stores(state)
            for relative in databases:
                assert not os.path.samefile(states[0] / relative, states[1] / relative), f"projects share {relative}"
            for folder in folders:
                assert not list(folder.rglob("*.db*")), "database escaped selected project state"
            descriptions = [json.loads((state / "local-mesh/mesh-owner.json").read_text()) for state in states[:2]]
            assert descriptions[0]["node"] != descriptions[1]["node"], "project node names collide"
            assert descriptions[0]["execution"] != descriptions[1]["execution"], "project executions collide"
            before = set(states[0].glob("owner-*.log"))
            third = NativeDesktop(binary, folders[0], None, arguments=("terminal",), home=home)
            views.append(third)
            third.wait(" BEE ", timeout=20)
            third.wait("Terminal", timeout=10)
            assert b"Connecting to Hive" in third.raw, "same folder did not select a display"
            assert set(states[0].glob("owner-*.log")) == before, "same folder started another owner"
            third.key(("test \"$PWD\" = " + shlex.quote(str(folders[0])) + " && printf 'REUSED_%s\\n' PROJECT\r").encode())
            third.wait("REUSED_PROJECT", timeout=10)
            client = NativeDesktop(binary, folders[0], None, arguments=("client",), home=home)
            views.append(client)
            client.wait(" BEE ", timeout=20)
            assert set(states[0].glob("owner-*.log")) == before, "explicit client started another owner"
            env = {key: value for key, value in os.environ.items() if key not in STATE_ENVIRONMENT}
            env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"))
            absent = subprocess.run([str(binary), "client"], cwd=folders[2], env=env,
                                    capture_output=True, text=True, timeout=10)
            assert absent.returncode != 0 and "No running Bee for this project" in absent.stderr + absent.stdout, absent
            assert not list(states[2].glob("owner-*.log")) and not list(states[2].glob("*.db"))
            explicit_state = root / "explicit-state"
            explicit = NativeDesktop(binary, folders[2], explicit_state, arguments=("terminal",), home=home)
            views.append(explicit)
            explicit.wait(" BEE ", timeout=30)
            owners.append(owner_handle(explicit, binary, explicit_state))
            explicit.wait("Terminal", timeout=10)
            check_stores(explicit_state)
            assert not list(states[2].glob("*.db*")), "explicit state also created default databases"
            assert not list(folders[2].rglob("*.db*")), "explicit state wrote databases in project folder"
            explicit.key(("test \"$PWD\" = " + shlex.quote(str(folders[2])) + " && printf 'EXPLICIT_%s\\n' CORRECT\r").encode())
            explicit.wait("EXPLICIT_CORRECT", timeout=10)
        finally:
            for view in reversed(views):
                view.close()
            for owner in owners:
                stop_owner(owner)
    print("Project executable: distinct folder nodes, terminal cwd, same-folder display reuse, explicit client refusal, every manifested DB plus client/registry isolation and explicit state override; Hive joining unverified")


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve())
