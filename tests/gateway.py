"""Gateway slice 1 on the managed fixture composition: the full source plus a
managed host that carries the loopback listener, and a probe that drives
readiness, admission, revocation, thread_read, bounded read-only thread_wait,
cross-attempt and expiry refusal, drain and epoch fencing against the real
listener and thread owner. The default source still declares no listener;
`tests/architecture.py` asserts that. Runs `run` on the staged host, so the
supervisor lane's pinned lint failure does not block it."""
from contextlib import ExitStack, contextmanager
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
from workspace import ROOT, RUNTIME, configure_managed_gateway, database_environment


@contextmanager
def gateway_workspace():
    with tempfile.TemporaryDirectory(prefix="bee-gateway-") as directory:
        folder = Path(directory)
        shutil.copytree(ROOT / "src", folder / "src")
        for name in (".wippy.yaml", "wippy.lock"):
            shutil.copy2(ROOT / name, folder / name)
        for child in (ROOT / "tests/modules/gateway/src").iterdir():
            if os.environ.get("BEE_GATEWAY_NATIVE") == "1" and child.name == "managed":
                continue
            shutil.copytree(child, folder / "src" / child.name)
        address = "native" if os.environ.get("BEE_GATEWAY_NATIVE") == "1" else configure_managed_gateway(folder)
        yield folder, address


def main():
    # The two probes execute together. Their independent /ready answers prove
    # fixture-local endpoint configuration prevents cross-runtime generation
    # conflicts rather than bypassing the gateway's generation verification.
    with ExitStack() as fixtures:
        workspaces = [fixtures.enter_context(gateway_workspace()) for _ in range(2)]
        addresses = [address for _, address in workspaces]
        if os.environ.get("BEE_GATEWAY_NATIVE") != "1":
            assert len(set(addresses)) == len(addresses), addresses
        runs = []
        try:
            for folder, _ in workspaces:
                runs.append(subprocess.Popen([str(RUNTIME), "run", "gateway-probe", "--set", f"registry.history_path={folder}/registry.db"],
                                             cwd=folder, env=database_environment(folder), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            for run, (_, address) in zip(runs, workspaces):
                stdout, stderr = run.communicate(timeout=120)
                output = stdout + stderr
                assert run.returncode == 0, f"{address}: {output}"
                assert "Bearer" not in output, "token bytes reached captured output"
        finally:
            for run in runs:
                if run.poll() is None:
                    run.terminate()
            for run in runs:
                if run.poll() is None:
                    try:
                        run.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        run.kill()
                        run.wait()
    print("Gateway slices 1, 2 and hook endpoints: hook credentials separate from tool credentials, empty-body answers, occurrence identity with replay and conflict, "
          "ambiguity per delivery, allowlisted queue fields, Codex metadata classification, payload and queue bounds; authenticated loopback readiness with epoch and restart generation, admission without bytes, materialize once per credential generation, "
          "reissue as compare-and-set, supersession and revoke_attempt fenced by carrier epoch, cross-attempt and expiry and revocation refused, thread_read as the bound subject, "
          "bounded read-only thread_wait with no delivery mark, drain releasing an in-flight wait with an explicit outcome and refusing admissions, a new epoch fencing earlier bindings, and a real funcs.new():with_scope configuration renderer whose callee is denied placement store, executor, policy lookup and scope creation; actor/context inheritance remains outside this scope-only proof")


if __name__ == "__main__":
    main()
