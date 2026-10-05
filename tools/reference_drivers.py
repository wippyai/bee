#!/usr/bin/env python3
"""Generate the docs corpus reference driver pages from the drivers in src.

Each page holds every file of one real driver verbatim, so an agent writing a
driver copies a complete, working definition. With --check, exit non-zero
when a page or its manifest record differs from what src produces.
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "src" / "corpus"
MANIFEST = CORPUS / "manifest.json"
DRIVERS = {"opencode": "OpenCode CLI"}
ORDER = ["env", "descriptor", "profiles", "credentials", "security", "binding"]
FENCE = {".yaml": "yaml", ".lua": "lua"}


def page(driver: str, title: str) -> str:
    base = ROOT / "src" / "driver" / driver
    files = sorted(
        (p for p in base.rglob("*") if p.is_file()),
        key=lambda p: (ORDER.index(p.parent.name) if p.parent.name in ORDER else len(ORDER),
                       p.name != "_index.yaml", str(p)),
    )
    parts = [
        f"# Reference driver: {title}",
        "",
        f"The complete `bee.driver.{driver}` driver, every file verbatim from Bee's source. "
        "A CLI driver is these entries: the env entries naming its executable, the CLI "
        "descriptor (version and help probes, login evidence, options), the profiles it admits, "
        "the credential projections, the security policies, and the binding whose prepare, "
        "dispatch, normalize, configure and locate functions implement the driver contract "
        "(`component/driver`).",
        "",
        "To write a driver for another CLI, author an overlay named `driver.<name>` (for example "
        "`driver.gemini`) and copy these files into it with every namespace renamed from "
        f"`bee.driver.{driver}` to `bee.driver.<name>`. An overlay driver defines its entries in "
        "`bee.driver.<name>.binding`, `.descriptor`, `.profiles`, `.security`, `.types` and `.credentials`. "
        "Its `.credentials` holds exactly one `bee.credential_format` for provider `<name>`: the login file "
        "under the home and any files to initialize beside it; profiles name the credential `<name>_login`, and "
        "the descriptor's `provider_home.files` list exactly those files: the login file with kind `login` "
        "and `source_path` equal to its path, each initialized file with kind `state` and no `source_path`, "
        "every file with a boolean `optional` and `write_back: false`, since an approved driver's "
        "machine login is admitted without write-back. "
        "Approving the driver lets its sessions use the person's machine login for that provider, and no "
        "other. The executable path is host configuration: leave `env/_index.yaml` out, and in each launch policy replace "
        "`executable_env` with `executables: {<executable>: <absolute path>}` naming the installed CLI, "
        "which the person reviews with the overlay. Change the descriptor, "
        "argv rendering and output "
        "normalization to the new CLI, then freeze and deliver it. The person approves the overlay "
        "and admits the new binding through harness activation (`component/agents`).",
        "",
    ]
    for path in files:
        relative = path.relative_to(base)
        parts.append(f"## {relative}")
        parts.append("")
        parts.append("```" + FENCE.get(path.suffix, ""))
        parts.append(path.read_text().rstrip("\n"))
        parts.append("```")
        parts.append("")
    return "\n".join(parts)


def main() -> int:
    check = "--check" in sys.argv[1:]
    manifest_text = MANIFEST.read_text()
    manifest = json.loads(manifest_text)
    documents = manifest["documents"]
    index = {d["id"]: i for i, d in enumerate(documents)}
    stale = []
    for driver, title in DRIVERS.items():
        doc_id = f"reference_drivers/{driver}"
        target = CORPUS / f"{doc_id}.md"
        content = page(driver, title)
        data = content.encode()
        record = {"bytes": len(data), "id": doc_id, "sha256": hashlib.sha256(data).hexdigest(),
                  "source": f"generated: tools/reference_drivers.py from src/driver/{driver}", "title": f"Reference driver: {title}",
                  "topic": "reference_drivers"}
        if not target.exists() or target.read_bytes() != data:
            stale.append(str(target.relative_to(ROOT)))
            if not check:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        if doc_id not in index:
            stale.append(f"manifest record {doc_id}")
            index[doc_id] = len(documents)
            documents.append(record)
        elif documents[index[doc_id]] != record:
            stale.append(f"manifest record {doc_id}")
            documents[index[doc_id]] = record
    manifest["totals"] = {"bytes": sum(d["bytes"] for d in documents), "documents": len(documents)}
    rendered = json.dumps(manifest, indent=2, sort_keys=True) + ("\n" if manifest_text.endswith("\n") else "")
    if rendered != manifest_text:
        if "manifest totals" not in stale and not any(s.startswith("manifest record") for s in stale):
            stale.append("manifest totals")
        if not check:
            MANIFEST.write_text(rendered)
    if check and stale:
        print("reference drivers are stale; run tools/reference_drivers.py: " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
