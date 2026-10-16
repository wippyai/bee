#!/usr/bin/env python3
"""Keep the docs corpus manifest true to its documents.

It generates reference drivers, the app capability catalog and the starter
app from their source definitions, and records every document's byte count
and SHA-256. With --check, exit non-zero when a page or manifest record differs
from its source.
"""
import hashlib
import json
import sys
import yaml
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
        "Its credential format is one `bee.credential_format` entry whose `meta.provider` is `<name>`; the "
        "activation requirement is an `ns.requirement` with `value_kind: contract.binding` whose `default` is the "
        "`contract.binding` of `meta.type: harness.driver` and whose single target appends to "
        "`bee.harness.launch:harness_activation` at `.bindings +=`. Admission reads these declared fields, so "
        "their identifiers may use any namespace the overlay owns. Its `.credentials` holds exactly one "
        "`bee.credential_format` for provider `<name>`: the login file "
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
        "and admits the new binding through harness activation (`component/harness`).",
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


REQUEST_EXAMPLE = """```yaml
- name: app
  kind: process.lua
  meta:
    type: bee.application
    application:
      api_version: 1
      lifetime: view
      title: Notes
      revision: '1'
      instance_policy: singleton
      menus: [bee.shell:apps_menu]
      capabilities:
      - capability: app.database
        parameters: {name: notes}
        reason: Keep the notes you write
      - capability: workspace.files.read
        parameters: {subpath: docs}
        reason: Show the documents in your docs folder
```"""

AUTHOR_ERRORS = [
    ("`<app> has meta.application but meta.type bee.app; set meta.type to bee.application`",
     "the application entry carries another meta.type; set `meta.type: bee.application`."),
    ("`workspace artifact declares no application; declare one process.lua entry with meta.type bee.application and meta.application`",
     "add the application's process.lua entry."),
    ("`<app> meta.application.capabilities must be a list of at most 8 {capability, parameters, reason} objects`",
     "write `capabilities` as a YAML list with at most eight items."),
    ("`<app> meta.application.capabilities[1]: unknown field target; it takes capability, parameters and reason`",
     "remove every other field; the host decides where the generated policy goes."),
    ("`<app> meta.application.capabilities[1].capability: files.read is not a host capability; expected one of ...`",
     "use an exact capability ID from this page."),
    ("`<app> meta.application.capabilities[1].reason must be one line of 1 to 512 characters saying why the app needs app.database`",
     "add a one-line `reason`."),
    ("`<app> meta.application.capabilities[1].parameters.subpath must be a relative workspace path such as data/notes, or . for the whole workspace`",
     "give the parameter in the form named after `must be`."),
    ("`<app> meta.application.capabilities[1].parameters.depth is not a parameter of workspace.files.read; it takes subpath`",
     "remove the parameter or use one the message lists."),
    ("`<app> meta.application.capabilities[1].parameters.tools: app.notes:search is not a function.lua tool in package app.notes`",
     "list only the package's own tool functions."),
    ("`<app> meta.application.capabilities[1].parameters.definitions: acme:worker is not a registry.entry with meta.type bee.launch_definition`",
     "name launch definitions only."),
    ("`<app> meta.application.capabilities[1].parameters.operations: app.notes:run is not a function.lua in package app.notes with meta.hive open`",
     "expose only the package's own functions whose `meta.hive` equals the requested mode."),
    ("`<app> meta.application.capabilities[2] repeats <app> meta.application.capabilities[1]`",
     "list each capability and parameter set once."),
    ("`app.notes:database: an ns.requirement has no meta.capability; list {capability, parameters, reason} in the application's meta.application.capabilities`",
     "move the request onto the application; keep `ns.requirement` for configuration and dependency bindings."),
    ("`installed capability grant record of <app> binds ns.requirement entries this host no longer reads; uninstall the application and install it again`",
     "the installed version used requirement entries for its capabilities; uninstall it in Library, then install the new version."),
    ("Preflight `APPLICATION_DESCRIPTOR`: `the desktop cannot open this application: meta.application.lifetime must be view`",
     "fix the named `meta.application` field and freeze a new version."),
    ("Preflight `MODULE_DENIED` naming `request capability process.exec ...`",
     "list the named capability in `meta.application.capabilities`, or remove the module."),
]


def capability_page() -> str:
    entries = yaml.safe_load((ROOT / "src/capability/_index.yaml").read_text())["entries"]
    catalog = next(entry["data"] for entry in entries if entry["name"] == "catalog")
    parts = ["# App capability catalog", "",
        f"App permissions: an app asks for host access by listing capabilities on its own application entry. Generated from the host catalog, revision {catalog['revision']}. A listed capability requests review; it grants nothing until the person approves it.", "",
        "Use docs search with topic capabilities and a task phrase, or ask `what can an app request to read workspace files`. Read the matching section here for the exact parameters and grants.", "",
        "## Request shape", "",
        "List what the app needs in `meta.application.capabilities` of its `process.lua` entry with `meta.type: bee.application`. Each item is `{capability, parameters, reason}`: `capability` is an exact ID below, `parameters` matches its parameter kinds (omit it for a capability that takes none), and `reason` is one line saying why the app needs it. The host generates the policies and attaches them to the application; do not write targets, paths or policies, and do not author an actor.", "",
        "For example, a database for my app and read access to one workspace folder:", "",
        REQUEST_EXAMPLE, "",
        "## How the person approves", "",
        "Delivering or installing the app files one approval in Needs you. It shows each listed capability in plain words, the catalog text below with your parameters filled in, together with the app's version and pending migrations. Approving installs the generated policies, databases, folders and executors with the app in one step; denying installs nothing. A later version's approval lists what it adds, widens, narrows or removes. Uninstalling removes the grants and keeps the app's databases.", "",
        "Risk class uses the catalog's confirmation class: standard means ordinary approval; explicit means deliberate confirmation for broader effects. Scope and the grant text describe the actual authority.", "",
        "## Errors and fixes", "",
        "Install preflight names the exact field and the value it expects. `<app>` stands for the application entry ID.", ""]
    for message, fix in AUTHOR_ERRORS:
        parts.append(f"- {message}: {fix}")
    parts.extend(["",
        "## Registry access and installed components", "",
        "No app capability grants registry access. Read installed components through the agent's components tool with operation installed, under its host-selected bee.hub.read policy. hub.manage grants an app Hub reads and changes; there is no read-only app capability. Calling an owner also needs its permitted call path; a capability never admits arbitrary funcs calls.", ""])
    for cap in catalog["capabilities"]:
        parts.extend([f"## {cap['id']}", "", f"{cap['id']}: {cap['text']}. Risk class: {cap['confirm']}. Template revision: {cap['revision']}.", ""])
        if cap['id'] == 'hub.self_update':
            parts.extend(["Host-only: only the person-operated Library receives this grant; an authored app cannot request Bee self-update.", ""])
        parts.extend(["Parameters: " + (", ".join(f"{name}: {kind}" for name, kind in cap["parameters"].items()) or "none") + ".",
            "Runtime modules admitted by this capability: " + (", ".join(cap.get("modules", [])) or "none") + ".",
            "Agent tools for an approved attempt: " + (", ".join(cap.get("tools", [])) or "none") + ".", "",
            "Grants:", ""])
        for policy in cap["policies"]:
            parts.append(f"- {policy['operation']} on {policy['resource']}, scope {json.dumps(policy['scope'], sort_keys=True)}")
        for resource in cap["resources"]:
            parts.append(f"- {resource['kind']} resource, mode {resource['mode']}, selected by {resource['source']}")
        parts.append("")
    parts.extend(["## Unavailable authority", "", "No app capability grants: " + ", ".join(catalog["never"]) + ". Use an isolated app database instead of Bee's core database; let the host select identity and policies; let the person decide approvals; run a view app when the person opens it instead of auto-starting a service.", ""])
    return "\n".join(parts)


def starter_page() -> str:
    entries = []
    base = ROOT / "tests/lua/support/starter"
    for index in sorted(base.rglob("_index.yaml")):
        document = yaml.safe_load(index.read_text())
        for row in document["entries"]:
            data = dict(row.get("data", {}))
            for field in ("source", "method", "modules", "imports"):
                if field in row:
                    value = row[field]
                    if field == "source":
                        value = (index.parent / value.removeprefix("file://")).read_text()
                    data[field] = value
            entry = {"id": document["namespace"] + ":" + row["name"], "kind": row["kind"], "data": data}
            if "meta" in row: entry["meta"] = row["meta"]
            entries.append(entry)
    return "# Minimal Bee starter app\n\nCopy this complete JSON array to entries.json in overlay hello. Replace all app.hello prefixes if you rename the overlay. The UI lives in .app, behaviour in .model and tests in .tests. It needs no extra capabilities; an app that needs one lists it on this entry, for example `\"capabilities\": [{\"capability\": \"app.database\", \"parameters\": {\"name\": \"greetings\"}, \"reason\": \"Keep the greetings you save\"}]` inside `meta.application`, and the person approves it at install (docs/app_capabilities). The source is the typed Lua fixture that Bee lints; the greeting tests exercise the same library the app uses. Follow docs/build_bee_app to freeze, preflight, deliver, approve and run the installed tests.\n\n## entries.json\n\n```json\n" + json.dumps(entries, indent=2, ensure_ascii=False).replace("bee.tests.support.starter.", "app.hello.") + "\n```\n"


def main() -> int:
    check = "--check" in sys.argv[1:]
    manifest_text = MANIFEST.read_text()
    manifest = json.loads(manifest_text)
    documents = manifest["documents"]
    index = {d["id"]: i for i, d in enumerate(documents)}
    stale = []
    generated = [(f"reference_drivers/{driver}", f"Reference driver: {title}",
                  "reference_drivers", f"src/driver/{driver}", page(driver, title))
                 for driver, title in DRIVERS.items()]
    generated.extend([
        ("docs/app_capabilities", "App capability catalog", "capabilities",
         "src/capability/_index.yaml", capability_page()),
        ("reference_apps/starter", "Minimal Bee starter app", "reference_apps",
         "tests/lua/support/starter", starter_page()),
    ])
    for doc_id, title, topic, source, content in generated:
        target = CORPUS / f"{doc_id}.md"
        data = content.encode()
        record = {"bytes": len(data), "id": doc_id, "sha256": hashlib.sha256(data).hexdigest(),
                  "source": f"generated: tools/corpus.py from {source}", "title": title,
                  "topic": topic}
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
    for record in documents:
        path = CORPUS / f"{record['id']}.md"
        if not path.exists():
            stale.append(f"missing document {record['id']}")
            continue
        data = path.read_bytes()
        measured = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        if any(record.get(name) != value for name, value in measured.items()):
            stale.append(f"manifest record {record['id']}")
            record.update(measured)
    manifest["totals"] = {"bytes": sum(d["bytes"] for d in documents), "documents": len(documents)}
    rendered = json.dumps(manifest, indent=2, sort_keys=True) + ("\n" if manifest_text.endswith("\n") else "")
    if rendered != manifest_text:
        if "manifest totals" not in stale and not any(s.startswith("manifest record") for s in stale):
            stale.append("manifest totals")
        if not check:
            MANIFEST.write_text(rendered)
    if check and stale:
        print("docs corpus is stale; run tools/corpus.py: " + ", ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
