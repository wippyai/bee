"""Docs-tool acceptance: a scripted fixture agent answers three questions it
could not know without the platform corpus.

The agent is admitted on the real authenticated MCP gateway for exactly the
`docs` tool, materializes its token once through the same admission and
credential path every managed Agent uses, and then, using only that tool,
answers one question about Bee's terminal toolkit, one about cross-node hive
subscriptions and one about a runtime module. Each answer is asserted inside
the probe against text the tool actually returned, so a corpus that silently
lost a page or a tool that widened its bounds fails this gate.

Required environment: BEE_RUNTIME (the combined runtime binary) only. The
corpus is the one embedded in this repository's src/ (docs_corpus); no network
is consulted, so this is also an offline proof for the corpus.
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workspace import RUNTIME, fixture_workspace, pack_fixture  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MARKERS = ("docs agent:", "tty.canvas", "subscribe(thread", "sql.builder.select")


def main():
    if not RUNTIME.is_file():
        sys.exit(f"BEE_RUNTIME must name the combined runtime binary; got {RUNTIME!r}")
    with fixture_workspace(managed_gateway=True) as folder:
        shutil.copytree(ROOT / "tests/fixtures/docs_agent", folder / "src/docs_agent")
        environment = {**os.environ}
        run = subprocess.run([str(RUNTIME), "run", "docs-agent-probe", "--host", "bee:terminal",
                              "--set", f"registry.history_path={folder}/registry.db"],
                             cwd=folder, env=environment, capture_output=True, text=True, timeout=180)
        output = re.sub(r"\x1b\[[0-9;]*m", "", run.stdout + run.stderr).replace("\r", "\n")
        assert run.returncode == 0, output[-4000:]
        answered = None
        for line in output.splitlines():
            if "docs agent:" in line:
                answered = line
        assert answered is not None, f"the fixture agent reported no answers:\n{output[-4000:]}"
        for marker in MARKERS:
            assert marker in answered, f"answer omitted {marker!r}: {answered}"
        assert "Bearer" not in output, "token bytes reached captured output"
        print("Docs agent: an admitted fixture agent answered the terminal toolkit, "
              "cross-node subscriptions and the SQL module from the embedded corpus")
        print(answered[:400])
        # The corpus must also travel inside a real pack: the same source, packed
        # with the test entries excluded, serves the manifest and a document from
        # the embedded read-only volume and refuses a write to it.
        pack = folder / "bee.wapp"
        # Production embeds the corpus through wippy.yaml's embed list; carry the
        # same declaration into the fixture so the packed probe exercises the
        # embedded filesystem, not a project directory.
        shutil.copy2(ROOT / "wippy.yaml", folder / "wippy.yaml")
        pack_fixture(folder, pack)
        packed = subprocess.run([str(RUNTIME), "run", str(pack), "docs-volume-probe", "--host", "bee:terminal"],
                                cwd=folder, env=environment, capture_output=True, text=True, timeout=180)
        packed_output = re.sub(r"\x1b\[[0-9;]*m", "", packed.stdout + packed.stderr).replace("\r", "\n")
        assert packed.returncode == 0, packed_output[-4000:]
        assert "read-only embedded filesystem" in packed_output, packed_output[-2000:]
        print("Docs corpus: the packed application serves the embedded read-only corpus with no network")


if __name__ == "__main__":
    main()
