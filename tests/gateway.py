"""Gateway slice 1 on the managed fixture composition: the full source plus a
managed host that carries the loopback listener, and a probe that drives
readiness, admission, revocation, thread_read, bounded read-only thread_wait,
cross-attempt and expiry refusal, drain and epoch fencing against the real
listener and thread owner. The default source still declares no listener;
`tests/architecture.py` asserts that. Runs `run` on the staged host, so the
supervisor lane's pinned lint failure does not block it."""
from pathlib import Path
import shutil
import subprocess
import tempfile
from workspace import ROOT, RUNTIME, database_environment


def main():
    with tempfile.TemporaryDirectory(prefix="bee-gateway-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "src", folder / "src")
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, folder / name)
        for child in (ROOT / "tests/modules/gateway/src").iterdir():
            shutil.copytree(child, folder / "src" / child.name)
        environment = database_environment(folder)
        result = subprocess.run([str(RUNTIME), "run", "gateway-probe", "--set", f"registry.history_path={folder}/registry.db"],
                                cwd=folder, env=environment, capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr
        assert result.returncode == 0, output
        assert "Bearer" not in output, "token bytes reached captured output"
    print("Gateway slices 1, 2 and hook endpoints: hook credentials separate from tool credentials, empty-body answers, occurrence identity with replay and conflict, "
          "ambiguity per delivery, allowlisted queue fields, Codex metadata classification, payload and queue bounds; authenticated loopback readiness with epoch and restart generation, admission without bytes, materialize once per credential generation, "
          "reissue as compare-and-set, supersession and revoke_attempt fenced by carrier epoch, cross-attempt and expiry and revocation refused, thread_read as the bound subject, "
          "bounded read-only thread_wait with no delivery mark, drain releasing an in-flight wait with an explicit outcome and refusing admissions, a new epoch fencing earlier bindings")


if __name__ == "__main__":
    main()
