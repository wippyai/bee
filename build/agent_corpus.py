# SPDX-License-Identifier: MIT
"""Build Bee's offline agent documentation corpus.

An agent inside Bee learns the application authoring contract from the workspace
tool's guide operation and from this embeddable, read-only filesystem. It carries
Bee's own contracts, every component README under src/ and modules/, the terminal
toolkit, and a small set of runtime references app authors use directly.

Storage shape: `src/corpus/` is declared by the host as one `fs.directory` entry
(`bee:docs_corpus`) that `wippy.yaml`'s `embed:` list names, so `wippy pack`
freezes it into the pack as an `fs.embed` volume the runtime serves read-only
(see docs/operations/native.md).

Selection rule, stated once and enforced by this table:

  * runtime references: only the Lua base and type system, channel, contract,
    process, registry, time, JSON, HTTP client, security, UUID, filesystem, SQL
    and TTY pages used by Bee application authors. The SQL reference includes
    `sql.builder`.
  * runtime tutorials, internals, general guides and platform material are out
    of this app-authoring corpus.

  * Bee contracts: the docs/ pages that state an implemented callable
    boundary or the path a frozen artifact travels, including application,
    thread, placement, gateway, carrier, storage and UI contracts. Repository
    process and design pages are left out.
  * component READMEs: one page per Bee component, the owner's own statement
    of that package's contract.
  * toolkit: one generated reference to Bee's terminal toolkit (tty plus the
    appearance, frame, visualization kit and application client libraries
    Bee's own apps use), with visualization examples taken from their golden
    tests and compact frame examples.

`--local` rebuilds every document generated from this repository and keeps
the committed runtime pages byte for byte (their digests are re-verified), so
the Bee part of the corpus refreshes without network access; the runtime
pages refresh only with a full networked build.

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

RUNTIME_PAGES = {
    "lua/core/base": "core",
    "lua/core/channel": "core",
    "lua/core/contract": "core",
    "lua/core/process": "core",
    "lua/core/registry": "core",
    "lua/core/time": "core",
    "lua/data/json": "data",
    "lua/http/client": "http",
    "lua/security/security": "security",
    "lua/security/uuid": "security",
    "lua/storage/filesystem": "storage",
    "lua/storage/sql": "storage",
    "lua/system/tty": "system",
    "lua/types": "lua",
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
    "guides/hub.md": ("registry", "hub_inspection"),
    "reference/agents/gateway.md": ("gateway", "gateway"),
    "reference/agents/hooks.md": ("gateway", "gateway_hooks"),
    "guides/agents/mcp.md": ("gateway", "mcp_configuration"),
    "development/package-boundaries.md": ("platform", "package_boundaries"),
    "reference/storage.md": ("storage", "storage"),
    "reference/sync-and-inbox.md": ("cluster", "sync_and_inbox"),
    "development/ownership.md": ("platform", "system_map"),
    "reference/threads.md": ("threads", "threads"),
    "guides/ui.md": ("ui", "ui_brand_book"),
    "guides/app-style.md": ("ui", "app_style"),
    "reference/workspace-state.md": ("storage", "workspace_state"),
    "reference/workspace-catalog.md": ("storage", "workspace_catalog"),
    "README.md": ("platform", "readme"),
}


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def get(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def runtime_selection() -> "list[tuple[str, str]]":
    """Only the runtime pages named by the app-authoring selection."""
    return sorted(RUNTIME_PAGES.items())


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


def lua_calls(source: str, prefix: str) -> "list[tuple[str, str]]":
    """One table row per documented `function M.name(...)` in a library."""
    rows = []
    for match in re.finditer(r"((?:^--[^\n]*\n)*)^function M\.([a-z_]+)\(([^)]*)\)(?:: ([^\n]+))?$", source, re.M):
        comment = " ".join(line[2:].strip() for line in match.group(1).splitlines())
        returns = f" -> {match.group(4)}" if match.group(4) else ""
        signature = f"{prefix}.{match.group(2)}({match.group(3)}){returns}".replace("|", "\\|")
        rows.append((match.group(2), f"| `{signature}` | {comment or 'See the source.'} |"))
    return rows


def lua_string(literal: str) -> str:
    """The value of one double-quoted Lua string literal without escapes beyond \\ and \"."""
    return re.sub(r'\\(["\\])', r"\1", literal[1:-1])


def golden_constants(source: str) -> "dict[str, list[str]]":
    """Every `local NAME: {string} = {"row", ...}` table of literal rows."""
    constants = {}
    for match in re.finditer(r"^local ([A-Z_]+): \{string\} = \{(.*?)\}$", source, re.M | re.S):
        rows = re.findall(r'"(?:[^"\\]|\\.)*"', match.group(2))
        constants[match.group(1)] = [lua_string(row) for row in rows]
    return constants


def statements(lines: "list[str]") -> "list[str]":
    """Group source lines into statements that close every bracket they open."""
    grouped, current, depth = [], [], 0
    for line in lines:
        current.append(line)
        depth += sum(line.count(c) for c in "({[") - sum(line.count(c) for c in ")}]")
        if depth <= 0:
            grouped.append("\n".join(current))
            current, depth = [], 0
    if current:
        grouped.append("\n".join(current))
    return grouped


def split_arguments(call: str) -> "list[str]":
    """The top-level arguments of `name(a, b)`."""
    body = call[call.index("(") + 1:call.rindex(")")]
    parts, current, depth, quote = [], "", 0, False
    index = 0
    while index < len(body):
        char = body[index]
        if quote:
            current += char
            if char == "\\":
                current += body[index + 1]
                index += 1
            elif char == '"':
                quote = False
        elif char == '"':
            quote, current = True, current + char
        elif char in "({[":
            depth, current = depth + 1, current + char
        elif char in ")}]":
            depth, current = depth - 1, current + char
        elif char == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += char
        index += 1
    parts.append(current.strip())
    return parts


def proven_examples(path: Path) -> "list[tuple[list[str], str]]":
    """The `-- example: a, b` blocks of a golden test as (names, markdown).

    A block runs to the next blank line, marker or `end)`. Its code is shown as
    written, each `test.eq(expr, value)` as `expr --> value` and each
    `golden(painter, NAME)` as the exact screen the test compares.
    """
    source = path.read_text()
    constants = golden_constants(source)
    lines = source.splitlines()
    examples = []
    index = 0
    while index < len(lines):
        marker = re.match(r"\s*-- example: (.+)$", lines[index])
        index += 1
        if not marker:
            continue
        body = []
        while index < len(lines) and lines[index].strip() and not lines[index].strip().startswith("-- example:") \
                and lines[index].strip() != "end)":
            body.append(lines[index])
            index += 1
        indent = min(len(line) - len(line.lstrip()) for line in body)
        code, screens = [], []
        for statement in statements([line[indent:] for line in body]):
            if statement.startswith("golden("):
                name = split_arguments(statement)[1]
                if name not in constants:
                    raise SystemExit(f"{path}: golden {name} is not a literal row table")
                screens.append(constants[name])
            elif statement.startswith("test.eq("):
                expression, expected = split_arguments(statement)
                code.append(f"{expression} --> {expected}")
            elif not statement.startswith("test."):
                code.append(statement)
        text = ["```lua", *code, "```"]
        for screen in screens:
            text += ["", "```text", *screen, "```"]
        examples.append(([name.strip() for name in marker.group(1).split(",")], "\n".join(text)))
    return examples


def lua_type_definitions(source: str) -> list[str]:
    """Read complete type declarations, including a record on several lines."""
    lines = source.splitlines()
    result = []
    index = 0
    while index < len(lines):
        match = re.match(r"^type ([A-Za-z]+ = .+)$", lines[index])
        if match:
            declaration = match.group(1)
            depth = declaration.count("{") - declaration.count("}")
            while depth > 0:
                index += 1
                if index >= len(lines):
                    raise SystemExit("incomplete Lua type declaration")
                part = lines[index].strip()
                declaration += " " + part
                depth += part.count("{") - part.count("}")
            result.append(declaration)
        index += 1
    return result


def toolkit_reference() -> bytes:
    """Bee's terminal toolkit, composed from the sources that define it."""
    client = (ROOT / "modules/application/src/client.lua").read_text()
    appearance = (ROOT / "modules/application/src/appearance.lua").read_text()
    frame = (ROOT / "modules/application/src/frame.lua").read_text()
    frame_api = [row for _, row in lua_calls(frame, "frame")]
    frame_types = lua_type_definitions(frame)
    if not frame_api or not frame_types:
        raise SystemExit("modules/application/src/frame.lua has no documented functions or types")
    viz = (ROOT / "modules/application/src/viz.lua").read_text()
    viz_calls = lua_calls(viz, "viz")
    viz_types = lua_type_definitions(viz)
    examples = proven_examples(ROOT / "tests/lua/frame/viz_test.lua")
    shown = {name for names, _ in examples for name in names}
    missing = [name for name, _ in viz_calls if name not in shown]
    if not viz_calls or not viz_types or missing:
        raise SystemExit(f"modules/application/src/viz.lua calls without a proven example: {missing}")
    gallery = []
    for names, text in examples:
        gallery += ["### " + ", ".join(f"`viz.{name}`" for name in names), "", text, ""]
    apps = sorted((ROOT / "src/apps").glob("*/view.lua"))
    calls = sorted(set(re.findall(r"tty\.[A-Za-z_.]+", client + appearance + frame + viz
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
        "* A frame is plain rows. Bee's apps draw every frame through",
        "  `bee.application:frame` (below), which reads the theme from",
        "  `require(\"appearance\").theme(preferences.theme)` and styles each run with a",
        "  semantic role; the view interprets nothing.",
        "* Layout is arithmetic on `width`/`height`; the frame bounds each run by display",
        "  width with an ellipsis and every app repaints on `resize` at the new size.",
        "* Input arrives as events; a `key` event carries `action` (`press`, `repeat`,",
        "  `release`) and the key identity. Bee's counter application increments on",
        "  every action except `release`, repaints and checkpoints, then leaves on",
        "  `process.event.CANCEL` after one last checkpoint.",
        "* `client.checkpoint(launch, json)` queues up to 64 KiB of app-owned JSON when",
        "  the application metadata declares a `resume_schema`; a start with a nonempty",
        "  `resume_state` restores from exactly that state.",
        "",
        "## Application frame",
        "",
        "`bee.application:frame` is the shared toolkit every Bee application draws with.",
        "Import it as `frame = \"bee.application:frame\"` next to `appearance`. One frame",
        "reads top to bottom: row 1 header (uppercase title, muted summary at the right),",
        "optional tabs, the work area (tables, rows, empty states), the action bar on the",
        "penultimate row with one primary button, and the footer on the final row with the",
        "status at the left and the key hints at the right. Selected rows keep their text,",
        "use the accent pair and carry a `›` marker in column 1. Hits are recorded as the",
        "frame draws; resolve mouse input with `frame.hit(hits, x, y)`.",
        "`frame.tabs` records each tab's `kind` as its hit kind; `frame.field`",
        "records hit kind `field` and the supplied index. `frame.layout` returns",
        "0 for omitted `tabs` and `actions` rows, and `Table.area` confines a table",
        "to one rectangle when a detail pane shares the screen.",
        "",
        "```lua",
        *[f"type {value}" for value in frame_types],
        "```",
        "",
        "| Call | Meaning |",
        "|------|---------|",
        *frame_api,
        "",
        "## Visualization kit",
        "",
        "`bee.application:viz` draws charts inside a `frame.Rect` of a frame painter,",
        "from semantic roles, and keeps live series bounded. Import it as",
        "`viz = \"bee.application:viz\"` next to `frame` and `appearance`. Every function is",
        "pure: the process owns `viz.series` rings, pushes one sample per tick and",
        "repaints when `viz.due` says a frame is due; the view reads `viz.values`. Choose",
        "the function by the question in `docs/app_style` section 12.",
        "",
        "```lua",
        *[f"type {value}" for value in viz_types],
        "```",
        "",
        "| Call | Meaning |",
        "|------|---------|",
        *[row for _, row in viz_calls],
        "",
        "## Visualization kit examples",
        "",
        "Each example below is a block of `tests/lua/frame/viz_test.lua`: the code as",
        "written, each checked value after `-->`, and the exact screen the golden test",
        "compares, with the frame's one blank cell at each edge.",
        "",
        *gallery,
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
        "## Toolkit names in this Bee revision",
        "",
        "`tty` members this repository's client, shared toolkit and bundled views call:",
        "",
        "```",
        " ".join(calls),
        "```",
        "",
        "The runtime module pages retained with this toolkit cover process, channel,",
        "contract, registry, time, JSON, types, security, UUID, filesystem, SQL, HTTP client",
        "and TTY APIs.",
        "",
        "## Compact frame example",
        "",
        "Compose a screen from the shared frame. The painter records mouse hits while",
        "drawing, and the returned rows can be presented after each resize or input event.",
        "",
        "```lua",
        "local frame = require(\"frame\")",
        "local painter = frame.new(width, height, preferences)",
        "frame.header(painter, \"TASKS\", \"3 open\")",
        "frame.tabs(painter, 2, {{kind = \"all\", label = \"All\"}, {kind = \"mine\", label = \"Mine\"}}, \"all\")",
        "frame.table(painter, 4, height - 2, {",
        "    columns = {{title = \"Task\", width = 0}, {title = \"State\", width = 12}},",
        "    cells = {{\"Billing\", \"Ready\"}, {\"Sync\", \"Waiting\"}},",
        "    kind = \"task\", selected = 1, offset = 0,",
        "})",
        "frame.actions(painter, height - 1, {{kind = \"open\", label = \"Open\", key = \"Enter\", enabled = true, primary = true}})",
        "frame.footer(painter, \"3 tasks\", frame.hints({{key = \"Enter\", verb = \"open\"}, {key = \"Esc\", verb = \"close\"}}))",
        "local rows, hits = frame.rows(painter), painter.hits",
        "```",
        "",
        "Resolve mouse input with `frame.hit(hits, x, y)`. Keep state and actions in",
        "the application, not the pure view.",
        "",
        "## Compact lifecycle example",
        "",
        "Present the first frame before reporting readiness. Recompute it from model",
        "state whenever input or a resize arrives.",
        "",
        "```lua",
        "local output = assert(tty.surface())",
        "local rows = draw(width, height, preferences)",
        "assert(output:present(rows))",
        "client.ready(launch)",
        "```",
        "",
    ]
    return ("\n".join(sections)).encode("utf-8")


def component_documents() -> "list[tuple[str, str, bytes, str]]":
    documents = []
    roots = [(ROOT / "src", None)]
    roots.extend((path, path.parent.name)
                 for path in sorted((ROOT / "modules").glob("*/src")))
    for root, module_name in roots:
        for path in sorted(root.rglob("README.md")):
            relative = path.relative_to(root)
            if module_name is None:
                identity = ":".join(relative.parts[:-1]) or "bee"
            else:
                identity = ":".join(module_name.split("-"))
                if relative.parts[:-1]:
                    identity += ":" + ":".join(relative.parts[:-1])
            documents.append((f"component/{identity}", "component", path.read_bytes(),
                              str(path.relative_to(ROOT))))
    return documents


def title_of(payload: bytes, fallback: str) -> str:
    """The document's own first heading, quoted form stripped for runtime pages."""
    for line in payload.decode("utf-8", "replace").splitlines():
        if line.startswith("# "):
            title = line[2:].strip().strip('"').strip()
            if title:
                return title[:120]
    return fallback[:120]


def committed_runtime() -> "list[tuple[str, str, bytes, str]]":
    """The selected committed runtime pages, re-verified against their digests."""
    if not MANIFEST.is_file():
        raise SystemExit("src/corpus/manifest.json is missing; run a networked `make agent-corpus` first")
    pages = []
    expected = {f"runtime/{path}" for path in RUNTIME_PAGES}
    seen = set()
    for document in json.loads(MANIFEST.read_text())["documents"]:
        if document["id"] not in expected:
            continue
        payload = (CORPUS / (document["id"] + ".md")).read_bytes()
        if digest(payload) != document["sha256"]:
            raise SystemExit(f"committed {document['id']} does not match its digest; run a networked build")
        pages.append((document["id"], document["topic"], payload, document["source"]))
        seen.add(document["id"])
    missing = expected - seen
    if missing:
        raise SystemExit(f"selected runtime pages are missing from the committed corpus: {', '.join(sorted(missing))}")
    if not pages:
        raise SystemExit("the committed corpus has no runtime pages; run a networked `make agent-corpus`")
    return pages


def build(local: bool = False) -> int:
    documents: "list[dict]" = []

    def record(identity, topic, payload, source):
        documents.append({"id": identity, "topic": topic, "source": source,
                          "title": title_of(payload, identity.rsplit("/", 1)[-1]),
                          "bytes": len(payload), "sha256": digest(payload), "content": payload})

    if local:
        for identity, topic, payload, source in committed_runtime():
            record(identity, topic, payload, source)
    else:
        selection = runtime_selection()
        fetched = fetch_runtime([path for path, _ in selection])
        for path, topic in selection:
            record(f"runtime/{path}", topic, fetched[path], f"{BASE}/path/en/{path}")
    for name, (topic, stable_name) in sorted(BEE_DOCS.items()):
        origin = ROOT / "docs" / name
        if not origin.is_file():
            raise SystemExit(f"docs/{name} is listed in the selection rule but missing")
        record(f"docs/{stable_name}", topic, origin.read_bytes(), f"docs/{name}")
    for identity, topic, payload, source in component_documents():
        record(identity, topic, payload, source)
    record("toolkit", "terminal", toolkit_reference(),
           "generated: modules/application/src, src/apps, tests/lua/frame")

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
    "Runtime reference: only the Lua base and type system, channel, contract, process, registry, time, JSON, HTTP client, "
    "security, UUID, filesystem, SQL and TTY pages used by Bee app authors; the SQL reference includes "
    "sql.builder. Runtime tutorials, internals, general guides and platform material are excluded. "
    "Bee contracts: the docs/ "
    "pages that state an implemented callable boundary or the path a frozen artifact travels "
    "(application, threads, placement, gateway, carrier, storage, ui, harness, approvals, "
    "registry, platform), excluding repository process and design pages. "
    "Component: one README per Bee package under src/ or modules/. Terminal toolkit: one generated page composed from "
    "modules/application/src, src/apps and compact examples; visualization examples are extracted from "
    "tests/lua/frame. The corpus is digest-checked with the rest."
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the committed corpus against its manifest without network access")
    parser.add_argument("--local", action="store_true",
                        help="rebuild repository-generated documents and keep selected runtime pages")
    arguments = parser.parse_args()
    return check() if arguments.check else build(arguments.local)


if __name__ == "__main__":
    sys.exit(main())
