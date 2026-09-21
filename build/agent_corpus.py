# SPDX-License-Identifier: MIT
"""Build Bee's offline agent documentation corpus.

An agent inside Bee learns the application authoring contract from the workspace
tool's guide operation and, until now, nothing else: it cannot look up how the
runtime's process, tty, registry, sql, http or fs modules work, nor Bee's own
contracts. This script snapshots the part of https://wippy.ai/llm an application
author calls, Bee's own contracts from docs/, every component README under src/
or a selected physical component source,
and one terminal toolkit reference, into an embeddable, read-only filesystem.

Storage shape: `src/corpus/` is declared as one `fs.directory` entry
(`bee.docs:corpus`) that `wippy.yaml`'s `embed:` list names, so `wippy pack` and
build/bundle.py both freeze it into the pack as an `fs.embed` volume the runtime
serves read-only (see docs/operations/native.md and tests/bundle_assets.py).

Selection rule, stated once and enforced by this table:

  * runtime *module reference*: every published page under `lua/**`, `system/**`
    and `http/**`, because those are the calls an application author makes and
    the component kinds behind them. The `lua/**` tree already carries the
    terminal toolkit's TTY module and the cross-node `events`/`process` pages.
  * runtime *named pages*: the concept, guide, internals and tutorial pages that
    explain the registry, entry kinds, cluster membership and terminal UI that
    the module pages assume.
  * excluded on purpose: `frontend/**` (browser micro-frontends, a different
    surface than Bee's terminal applications), `framework/**`, `temporal/**`,
    `wasm/**` and `about/**`.

  * Bee contracts: the docs/ pages that state an implemented callable
    boundary or the path a frozen artifact travels, including application,
    thread, placement, gateway, carrier, storage and UI contracts. Repository
    process and design pages are left out.
  * component READMEs: one page per source component, the owner's own statement
    of that package's contract.
  * toolkit: one generated reference to Bee's terminal toolkit (tty plus the
    appearance and application client libraries Bee's own apps use).

`manifest.json` carries, per document, its stable id, topic, source and digest,
plus the totals and this rule, so the corpus cannot silently rot; `--check`
re-verifies every digest offline.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "src" / "corpus"
MANIFEST = CORPUS / "manifest.json"
BASE = "https://wippy.ai/llm"
SCHEMA = "bee.docs-corpus@1"
MAX_CORPUS_BYTES = 3 * 1024 * 1024
USER_AGENT = "bee-agent-corpus/1 (+https://bee.wippy.ai)"

RUNTIME_ROOTS = ("lua", "system", "http")
RUNTIME_PAGES = {
    "start/llm-brief": "platform",
    "start/structure": "platform",
    "concepts/architecture": "platform",
    "concepts/compute-units": "platform",
    "concepts/functions": "platform",
    "concepts/process-model": "process",
    "concepts/registry": "registry",
    "concepts/cluster": "cluster",
    "concepts/security-model": "security",
    "concepts/workflows": "process",
    "guides/entry-kinds": "registry",
    "guides/components": "registry",
    "guides/cluster": "cluster",
    "guides/cluster": "cluster",
    "guides/dependency-management": "registry",
    "guides/artifacts": "registry",
    "guides/supervision": "process",
    "internals/architecture": "platform",
    "internals/registry": "registry",
    "internals/kinds": "registry",
    "internals/modules": "registry",
    "internals/events": "cluster",
    "internals/dispatch": "process",
    "internals/scheduler": "process",
    "tutorials/hello-world": "platform",
    "tutorials/processes": "process",
    "tutorials/channels": "process",
    "tutorials/supervision": "process",
    "tutorials/tty": "terminal",
    "tutorials/facade": "registry",
    "tutorials/task-queue": "process",
    "tutorials/echo-service": "http",
}
# Source paths are organized for readers; IDs remain stable because they are
# part of the offline tool's durable contract. Do not derive an ID from a path.
BEE_DOCS = {
    "development/agent-guide.md": ("platform", "agent_guide"),
    "reference/applications.md": ("application", "application_contracts"),
    "reference/approvals.md": ("approvals", "approvals"),
    "reference/agents/carrier.md": ("application", "carrier"),
    "guides/desktop.md": ("ui", "desktop"),
    "guides/overlays.md": ("application", "distributed_app_delivery"),
    "reference/agents/gateway.md": ("gateway", "gateway"),
    "reference/agents/hooks.md": ("gateway", "gateway_hooks"),
    "guides/agents/mcp.md": ("gateway", "mcp_configuration"),
    "development/package-boundaries.md": ("platform", "package_boundaries"),
    "reference/storage.md": ("storage", "storage"),
    "reference/sync-and-inbox.md": ("cluster", "sync_and_inbox"),
    "development/ownership.md": ("platform", "system_map"),
    "reference/threads.md": ("threads", "threads"),
    "guides/ui.md": ("ui", "ui_brand_book"),
    "reference/workspace-state.md": ("storage", "workspace_state"),
    "README.md": ("platform", "readme"),
}


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def get(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def toc_paths() -> "list[str]":
    document = json.loads(get(f"{BASE}/toc"))
    pages: "list[str]" = []

    def walk(items):
        for item in items:
            if "children" in item:
                walk(item["children"])
            elif isinstance(item.get("path"), str):
                pages.append(item["path"])

    walk(document["items"])
    return pages


def runtime_selection() -> "list[tuple[str, str]]":
    """Every module page under the selected roots plus the named pages."""
    selected = {}
    for path in toc_paths():
        if path.split("/", 1)[0] in RUNTIME_ROOTS:
            # lua/core/process -> core, lua/storage/sql -> storage, system/terminal -> component
            parts = path.split("/")
            topic = parts[1] if parts[0] == "lua" and len(parts) > 2 else parts[0]
            selected[path] = topic
    for path, topic in RUNTIME_PAGES.items():
        selected.setdefault(path, topic)
    return sorted(selected.items())


def fetch_runtime(paths: "list[str]") -> "dict[str, bytes]":
    """Fetch each published page exactly once.

    The batch endpoint answers with unrelated pages appended, so a per-page
    fetch is the only form that maps one published page to one corpus document.
    """
    fetched: "dict[str, bytes]" = {}

    def one(path):
        body = get(f"{BASE}/path/en/{urllib.parse.quote(path, safe='/')}")
        if not body.startswith(b"# "):
            raise SystemExit(f"published page {path} did not answer markdown")
        return path, body.rstrip() + b"\n"

    with ThreadPoolExecutor(max_workers=8) as pool:
        for path, body in pool.map(one, paths):
            fetched[path] = body
    return fetched


def toolkit_reference() -> bytes:
    """Bee's terminal toolkit, composed from the sources that define it."""
    guide = (ROOT / "src/governance/guide.lua").read_text()
    source_match = re.search(r"M[.]SOURCE = \[==\[(.*?)\]==\]", guide, re.DOTALL)
    if not source_match:
        raise SystemExit("src/governance/guide.lua has no bounded M.SOURCE example")
    guide_source = source_match.group(1).strip()
    client = (ROOT / "src/ui/application/client.lua").read_text()
    appearance = (ROOT / "src/ui/appearance.lua").read_text()
    stylebook_manifest = (ROOT / "src/apps/stylebook/_index.yaml").read_text().rstrip()
    stylebook_app = (ROOT / "src/apps/stylebook/app.lua").read_text().rstrip()
    stylebook_view = (ROOT / "src/apps/stylebook/view.lua").read_text().rstrip()
    apps = sorted((ROOT / "src/apps").glob("*/view.lua"))
    calls = sorted(set(re.findall(r"tty\.[A-Za-z_.]+", client + appearance + guide_source
                                  + "".join(p.read_text() for p in apps))))
    sections = [
        "# Bee terminal toolkit",
        "",
        "How a Bee application draws. An application is one `process.lua` entry whose",
        "source is inline Lua; it renders into the window broker's terminal through the",
        "native `tty` module and exchanges lifecycle with `bee.application:client`.",
        "This page is generated by `build/agent_corpus.py` from Bee's own sources, so it",
        "cannot drift from them; the runtime reference below lists every call.",
        "",
        "## Lifecycle",
        "",
        "```lua",
        "local tty = require(\"tty\")",
        "local client = require(\"client\")",
        "local process = require(\"process\")",
        "local channel = require(\"channel\")",
        "local output = assert(tty.surface())   -- once, before painting",
        "assert(tty.start())                    -- enter raw mode after surface()",
        "local input = assert(tty.events())     -- key, resize and close events",
        "local lifecycle = assert(process.events())",
        "local width, height = tty.screen_size()",
        "local canvas = tty.canvas(width, height)",
        "canvas:clear(\" \")                       -- one-based cells",
        "canvas:put(1, 1, \"COUNTER APP\", width)",
        "assert(output:present(canvas:rows()))  -- one frame per paint",
        "client.ready(launch)                   -- after the first paint",
        "output:close(); tty.stop()             -- on process.event.CANCEL",
        "```",
        "",
        "## Toolkit calls used by Bee's own applications",
        "",
        "| Call | Meaning |",
        "|------|---------|",
        "| `tty.surface()` | The presentation surface for this process frame |",
        "| `tty.events()` | Input channel: `key`, `resize` and `close` events |",
        "| `tty.start()` / `tty.stop()` | Enter and leave raw terminal mode |",
        "| `tty.screen_size()` | Current width and height, updated by resize |",
        "| `tty.canvas(w, h)` | One frame; `put(x, y, text, width)` is one-based |",
        "| `output:present(rows)` | Present one frame; rows come from `canvas:rows()` |",
        "| `tty.attach(mount)` | Attach to another window's mounted view |",
        "| `tty.text.width/truncate` | Display width and bounded truncation |",
        "",
        "## Layout, styles and input",
        "",
        "* A frame is plain rows. Bee's apps read the theme from",
        "  `require(\"appearance\").theme(preferences.theme)` and wrap styled runs as",
        "  `appearance.style(fg, bg) .. text .. \"\\27[0m\"`; the view interprets nothing.",
        "* Layout is arithmetic on `width`/`height`; `tty.text.truncate` bounds each run",
        "  and every app repaints on `resize` at the new size.",
        "* Input arrives as events; a `key` event carries `action` (`press`, `repeat`,",
        "  `release`) and the key identity. Bee's counter application increments on",
        "  every action except `release`, repaints and checkpoints, then leaves on",
        "  `process.event.CANCEL` after one last checkpoint.",
        "* `client.checkpoint(launch, json)` queues up to 64 KiB of app-owned JSON when",
        "  the application metadata declares a `resume_schema`; a start with a nonempty",
        "  `resume_state` restores from exactly that state.",
        "",
        "## Application client",
        "",
        "```lua",
        "local client = require(\"client\")",
        "local launch = client.launch(value)          -- validated launch record",
        "client.ready(launch)                          -- window may present",
        "client.checkpoint(launch, json.encode(state)) -- queued, not acknowledged",
        "client.title(launch, \"Title\")                 -- bounded title update",
        "client.reference(launch)                      -- logical view reference",
        "```",
        "",
        "Read `docs/reference/applications.md` in this corpus for the full record,",
        "including negotiated close, shell queries and appearance.",
        "",
        "## Minimal authored application",
        "",
        "This is the exact inline source returned by Governance's read-only authoring",
        "guide in this Bee revision. It demonstrates semantic appearance, bounded",
        "responsive rows, keyboard/mouse parity and correlated checkpoint receipts.",
        "",
        "```lua",
        guide_source,
        "```",
        "",
        "## Toolkit names in this Bee revision",
        "",
        "`tty` and `appearance`/`client` members this repository actually calls:",
        "",
        "```",
        " ".join(calls),
        "```",
        "",
        "The native module reference is the `tty`, `appearance` and `filesystem` pages",
        "under `runtime/lua/` and `runtime/system/` in this corpus. The guide example in",
        "`src/governance/guide.lua` is the minimal working application.",
        "",
        "## Canonical UI Guide source",
        "",
        "These are the exact files used by Bee's runnable **Tools → Learn → UI Guide**",
        "in this revision. Copy its process/view split, resize handling, bounded cell",
        "geometry and keyboard/mouse parity as a starting point. Keep application-specific",
        "state and actions in the authored app; this reference is not a widget framework.",
        "",
        "### Registry manifest (`src/apps/stylebook/_index.yaml`)",
        "",
        "```yaml",
        stylebook_manifest,
        "```",
        "",
        "### Process (`src/apps/stylebook/app.lua`)",
        "",
        "```lua",
        stylebook_app,
        "```",
        "",
        "### Pure view (`src/apps/stylebook/view.lua`)",
        "",
        "```lua",
        stylebook_view,
        "```",
        "",
    ]
    return ("\n".join(sections)).encode("utf-8")


def component_documents() -> "list[tuple[str, str, bytes, str]]":
    documents = []
    for path in sorted((ROOT / "src").rglob("README.md")):
        relative = path.relative_to(ROOT / "src")
        identity = ":".join(relative.parts[:-1]) or "bee"
        documents.append((f"component/{identity}", "component", path.read_bytes(), f"src/{identity}"))
    persist = ROOT / "modules" / "bee-persist" / "src" / "README.md"
    documents.append(("component/persist", "component", persist.read_bytes(), "modules/bee-persist/src"))
    return documents


def title_of(payload: bytes, fallback: str) -> str:
    """The document's own first heading, quoted form stripped for runtime pages."""
    for line in payload.decode("utf-8", "replace").splitlines():
        if line.startswith("# "):
            title = line[2:].strip().strip('"').strip()
            if title:
                return title[:120]
    return fallback[:120]


def build() -> int:
    selection = runtime_selection()
    fetched = fetch_runtime([path for path, _ in selection])
    documents: "list[dict]" = []

    def record(identity, topic, payload, source):
        documents.append({"id": identity, "topic": topic, "source": source,
                          "title": title_of(payload, identity.rsplit("/", 1)[-1]),
                          "bytes": len(payload), "sha256": digest(payload), "content": payload})

    for path, topic in selection:
        record(f"runtime/{path}", topic, fetched[path], f"{BASE}/path/en/{path}")
    for name, (topic, stable_name) in sorted(BEE_DOCS.items()):
        origin = ROOT / "docs" / name
        if not origin.is_file():
            raise SystemExit(f"docs/{name} is listed in the selection rule but missing")
        record(f"docs/{stable_name}", topic, origin.read_bytes(), f"docs/{name}")
    for identity, topic, payload, source in component_documents():
        record(identity, topic, payload, source)
    record("toolkit", "terminal", toolkit_reference(), "generated: src/ui, src/apps, src/governance/guide.lua")

    total = sum(document["bytes"] for document in documents)
    if total > MAX_CORPUS_BYTES:
        raise SystemExit(f"corpus is {total} bytes, over the {MAX_CORPUS_BYTES} byte ceiling")

    if CORPUS.exists():
        shutil.rmtree(CORPUS)
    CORPUS.mkdir(parents=True)
    for document in documents:
        target = CORPUS / (document["id"] + ".md")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(document.pop("content"))
    manifest = {"schema": SCHEMA, "selection_rule": SELECTION_RULE, "base": BASE,
                "ceiling_bytes": MAX_CORPUS_BYTES,
                "totals": {"documents": len(documents), "bytes": total},
                "documents": documents}
    MANIFEST.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"corpus: {len(documents)} documents, {total} bytes, ceiling {MAX_CORPUS_BYTES}")
    for topic, count in sorted(topic_totals(documents).items()):
        print(f"  {topic}: {count}")
    return 0


def topic_totals(documents) -> "dict[str, int]":
    totals: "dict[str, int]" = {}
    for document in documents:
        totals[document["topic"]] = totals.get(document["topic"], 0) + 1
    return totals


def check() -> int:
    if not MANIFEST.is_file():
        raise SystemExit("src/corpus/manifest.json is missing; run `make agent-corpus`")
    manifest = json.loads(MANIFEST.read_text())
    failures = 0
    for document in manifest["documents"]:
        path = CORPUS / (document["id"] + ".md")
        if not path.is_file():
            print(f"missing {path.relative_to(ROOT)}")
            failures += 1
            continue
        payload = path.read_bytes()
        if len(payload) != document["bytes"] or digest(payload) != document["sha256"]:
            print(f"changed {path.relative_to(ROOT)}")
            failures += 1
    stale = {path for path in CORPUS.rglob("*.md")} - {CORPUS / (document["id"] + ".md")
                                                       for document in manifest["documents"]}
    for path in sorted(stale):
        print(f"undeclared {path.relative_to(ROOT)}")
        failures += 1
    total = sum(document["bytes"] for document in manifest["documents"])
    if total > manifest["ceiling_bytes"]:
        print(f"corpus {total} bytes exceeds its declared ceiling")
        failures += 1
    if failures:
        raise SystemExit(f"corpus check failed: {failures} mismatches")
    print(f"corpus check: {manifest['totals']['documents']} documents, {total} bytes, all digests match")
    return 0


SELECTION_RULE = (
    "Runtime reference: every published wippy.ai/llm page under lua/**, system/** and http/** "
    "(the native modules an application author calls and the component kinds behind them), plus "
    "the named concept, guide, internals, tutorial and platform pages this project lists; "
    "frontend/**, framework/**, temporal/**, wasm/** and about/** are excluded because they are "
    "another product surface, not the terminal application contract. Bee contracts: the docs/ "
    "pages that state an implemented callable boundary or the path a frozen artifact travels "
    "(application, threads, placement, gateway, carrier, storage, ui, harness, approvals, "
    "registry, platform), excluding repository process and design pages. "
    "Component: one README per source component. Terminal toolkit: one generated page composed from "
    "src/ui, src/apps and src/governance/guide.lua and digest-checked with the rest."
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the committed corpus against its manifest without network access")
    arguments = parser.parse_args()
    return check() if arguments.check else build()


if __name__ == "__main__":
    sys.exit(main())
