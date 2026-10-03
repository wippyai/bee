# SPDX-License-Identifier: MIT
"""Public, source-free Bee journey. Failures retain their cause and evidence."""
import argparse
from contextlib import closing
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import shutil
import selectors
import sqlite3
import subprocess
import time

from native_client import hold_owner, live_owners, stop_owner
from native_workspace import NativeDesktop, STATE_ENVIRONMENT

ROOT = Path(__file__).resolve().parents[1]
SENSITIVE = re.compile(r"^credentials\.db.*$|secret|token|key", re.I)
TRANSIENT = re.compile(r"(?:^|\.)lock$|\.pid$|\.log$|-(?:wal|shm|journal)$", re.I)
DATABASE = re.compile(r"\.db(?:\..*)?$|\.sqlite$", re.I)
START_FAILURE = re.compile(r"BEE_STARTUP_FAILED[^\r\n]*|bee: failed[^\r\n]*|Backfill retained application alias[^\r\n]*|(?:startup|restore|migration|boot)[^\r\n]*(?:failed|failure)|dependency resolution failed[^\r\n]*", re.I)
FAILURE = re.compile(r"start_failed|LOGIN_REQUIRED|PROTECTED_KERNEL|(?:^|\W)(?:FAILED|Error:|START_FAILED|STARTUP_FAILURE)(?:\W|$)")
MARKER = "OWNER JOURNEY ANSWER"
STUB_MARKER = "OWNER JOURNEY STUB OUTPUT"


class JourneyFailure(AssertionError):
    pass


def require(condition, cause):
    if not condition:
        raise JourneyFailure(cause)


def safe_copy(source, destination):
    """Do not open excluded files; backup SQLite through a read-only connection."""
    require(source.is_dir(), f"BEE_SOURCE_STATE is not a directory: {source}")
    require(not source.is_symlink(), "BEE_SOURCE_STATE must be a physical directory")
    source, destination = source.resolve(), destination.resolve()
    require(source != destination and source not in destination.parents and destination not in source.parents,
            "source and scratch state must be disjoint")
    destination.mkdir(parents=True)
    copied, excluded = [], []

    def visit(folder, target):
        for item in sorted(folder.iterdir()):
            relative = item.relative_to(source)
            if SENSITIVE.search(item.name):
                excluded.append({"path": str(relative), "reason": "sensitive name"})
                continue
            if TRANSIENT.search(item.name) and item.name.lower() not in {"wippy.lock", "resolution.lock"}:
                excluded.append({"path": str(relative), "reason": "log, process lock/pid or SQLite sidecar"})
                continue
            output = target / item.name
            if item.is_symlink():
                subprocess.run(["cp", "-a", "--", str(item), str(output)], check=True)
                copied.append(str(relative))
            elif item.is_dir():
                output.mkdir()
                visit(item, output)
                shutil.copystat(item, output)
            elif item.is_file():
                # SQLite backup includes committed WAL pages. Never copy a WAL
                # beside its backup; workspace.db.client is also an owner DB.
                if DATABASE.search(item.name):
                    with closing(sqlite3.connect(item.as_uri() + "?mode=ro", uri=True)) as original:
                        original.execute("BEGIN")
                        original.execute("SELECT name FROM sqlite_master LIMIT 1").fetchall()
                        with closing(sqlite3.connect(output)) as backup:
                            original.backup(backup)
                    shutil.copystat(item, output)
                else:
                    subprocess.run(["cp", "-a", "--", str(item), str(output)], check=True)
                copied.append(str(relative))
            else:
                excluded.append({"path": str(relative), "reason": "non-regular state entry"})
    visit(source, destination)
    require(not (destination / "credentials.db").exists(), "credentials store was copied")
    return {"copied": copied, "excluded": excluded}


def rows(state, database, query, parameters=()):
    """Read test evidence, never mutate owner tables or open the credential store."""
    require(not SENSITIVE.search(database), "refusing sensitive store")
    path = state / database
    if not path.exists():
        return []
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as connection:
        connection.row_factory = sqlite3.Row
        return [dict(row) for row in connection.execute(query, parameters)]


def table_exists(state, database, name):
    return bool(rows(state, database, "SELECT name FROM sqlite_master WHERE type='table' AND name=?", (name,)))


def governance_failure(text):
    return (re.search(r"\b[A-Z][A-Z_]+: ", text) is not None
            or "Request failed:" in text or "No answer from the destination" in text
            or "Owner acknowledged the step without a new activation" in text)


def applications(state):
    if not table_exists(state, "workspace.db", "workspace_state"):
        return []
    result = []
    for row in rows(state, "workspace.db", "SELECT workspace_id,value FROM workspace_state"):
        value = json.loads(row["value"])
        for app in value.get("applications", []):
            result.append({"workspace": row["workspace_id"], **app})
    return result


def sessions(state):
    if not table_exists(state, "threads.db", "bee_sessions"):
        return []
    return rows(state, "threads.db", "SELECT session_ref,thread_id,title,state,route_json FROM bee_sessions")


def progress(state):
    # Revision/phase changes are owner events, rather than database mtimes or ticks.
    result = []
    for database, table, columns in (("threads.db", "bee_session_work", "work_ref,revision,phase"),
                                     ("approvals.db", "bee_approval_requests", "approval_id,revision,state")):
        if table_exists(state, database, table):
            result.append(rows(state, database, f"SELECT {columns} FROM {table} ORDER BY 1"))
    return json.dumps(result, sort_keys=True)


class LocalHub:
    """Reuse the repo's isolated loopback Hub and sealed-pack mutation fixture."""
    def __init__(self, binary, scratch, environment, bound):
        import yaml
        deployment = binary.parent / "portable-deployment/hub"
        require((deployment / "wippy.lock").is_file(),
                "local Hub fixture needs the standalone's sibling portable-deployment/hub sealed artifacts")
        self.folder = scratch / "hub-fixture"
        self.folder.mkdir()
        self.process = None
        self.log = None
        lock = yaml.safe_load((deployment / "wippy.lock").read_text())
        packs, artifacts = [], {}
        target = "0.1.0-ownerjourney.1"
        for row in lock["modules"]:
            name, version = row["name"], row["version"]
            original = deployment / ".wippy/vendor" / (name + "-" + version + ".wapp")
            require(original.is_file(), "sealed fixture artifact missing: " + str(original))
            artifacts[name + "@" + version] = str(original)
            if name.split("/", 1)[0] == "bee":
                output = self.folder / (name.replace("/", "-") + ".wapp")
                packs.append({"Input": str(original), "Output": str(output), "Version": target,
                              "DependencyVersion": target, "Component": name})
                artifacts[name + "@" + target] = str(output)
        config = self.folder / "packs.json"
        config.write_text(json.dumps({"Packs": packs, "Sources": {
            "bee.settings.app:view": str(ROOT / "modules/settings/src/app/view.lua")}}))
        env = {**environment, "HOME": str(Path.home()), "GOWORK": "off", "GOTOOLCHAIN": "go1.27.0"}
        subprocess.run(["go", "-C", str(ROOT / "native"), "run", "-mod=readonly",
                        str(ROOT / "tests/standalone_self_update_packs.go"), str(config)],
                       env=env, check=True, capture_output=True, text=True, timeout=bound)
        descriptions, paths = self.folder / "entries.json", self.folder / "artifacts.json"
        descriptions.write_text("{}")
        paths.write_text(json.dumps(artifacts))
        fixture = self.folder / "hub"
        subprocess.run(["go", "-C", str(ROOT / "native"), "build", "-mod=readonly", "-o", str(fixture),
                        str(ROOT / "tests/hub_migration_fixture.go")], env=env, check=True,
                       capture_output=True, text=True, timeout=bound)
        self.log = (self.folder / "transport.log").open("w")
        self.process = subprocess.Popen([str(fixture), str(descriptions), str(paths)], env=env,
                                        stdout=subprocess.PIPE, stderr=self.log, text=True)
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            require(bool(selector.select(timeout=bound)), f"local Hub readiness no-progress hang bound ({bound:g}s)")
            self.url = self.process.stdout.readline().strip()
        require(self.url.startswith("http://127.0.0.1:"), "local Hub fixture did not publish a loopback endpoint")
        self.marker = "proof marker " + target

    def close(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)  # declared fixture stop grace
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.process:
            self.process.stdout.close()
        if self.log:
            self.log.close()


@dataclass
class Step:
    number: int
    title: str
    status: str = "FAIL"
    seconds: float = 0
    cause: str = "not reached"
    frames: list[str] = field(default_factory=list)
    approvals: int = 0
    annoyances: list[str] = field(default_factory=list)


class JourneyDesktop(NativeDesktop):
    """Use the existing complete-frame decoder; wait on state with a hang bound."""
    def __init__(self, journey, folder, state, environment):
        self.journey, self.state, self.folder = journey, state, folder
        self.observed_frames = []
        super().__init__(journey.binary, folder, state, environment=environment)

    def pump(self, duration=.1):
        super().pump(duration)
        if self.journey.current:
            (self.journey.scratch / f"{self.journey.current.number:02d}-latest.frame.txt").write_text(self.text() + "\n")
        self.journey.observe(self)

    def wait(self, text, timeout=None):
        self.wait_until(lambda: text in self.text(), repr(text), timeout)

    def wait_until(self, condition, description, timeout=None):
        bound = timeout or self.journey.hang_seconds
        if self.journey.current:
            (self.journey.scratch / f"{self.journey.current.number:02d}-wait.txt").write_text(description + "\n")
        last_progress = time.monotonic()
        seen = set()
        while True:
            self.pump()
            if condition():
                return
            if self.process.poll() is not None:
                raise JourneyFailure(f"Bee presenter EXIT {self.process.returncode} while waiting for {description}: {self.text().strip()}")
            frame = re.sub(r"\b\d\d:\d\d(?::\d\d)?\b|[▏▎▍▌▋▊▉]", "", self.text())
            frame = re.sub(r"\d{4}-\d{2}-\d{2}T[\d:.]+Z", "sample time", frame)
            frame = re.sub(r"heap [\d.]+ MiB|goroutines \d+", "telemetry", frame)
            observed = (frame, progress(self.state))
            if observed not in seen:
                seen.add(observed)
                last_progress = time.monotonic()
            if time.monotonic() - last_progress >= bound:
                raise JourneyFailure(f"no-progress hang bound ({bound:g}s) waiting for {description}; no new rendered state or owner revision was observed")

    def quit(self, confirm=False):
        started = time.monotonic()
        self.key(b"\x11")
        if confirm:
            self.wait("Quit Bee?")
            self.key(b"\t\r")
        self.wait_until(lambda: self.process.poll() is not None, "presenter EXIT acknowledgement")
        require(self.process.returncode == 0, f"Bee presenter EXIT {self.process.returncode} during quit")
        return time.monotonic() - started

    def open_start(self):
        visible = lambda: any("Apps " in line and "│" in line and line.index("│") < line.index("Apps ")
                              for line in self.screen.display[1:])
        if visible():
            return
        if " BEE ▴" in self.text():
            self.mouse(0, 3, 1)
            self.mouse(0, 3, 1, True)
            self.wait(" BEE ▾")
        self.mouse(0, 3, 1)
        self.mouse(0, 3, 1, True)
        self.wait_until(visible, "launcher")


class Journey:
    def __init__(self, binary, source, output, hang_seconds=600, author_provider="Claude Code"):
        self.binary, self.source, self.output = binary.resolve(), source.resolve(), output.resolve()
        self.hang_seconds = hang_seconds
        self.author_provider = author_provider
        work_root = (ROOT / ".wippy/owner-journey-work").resolve()
        require(self.source != self.output and self.source not in self.output.parents
                and self.source != work_root and self.source not in work_root.parents,
                "source must not contain the evidence or scratch roots")
        self.output.mkdir(parents=True, exist_ok=True)
        self.scratch = self.output / ("run-" + time.strftime("%Y%m%d-%H%M%S") + "-" + str(os.getpid()))
        self.scratch.mkdir(mode=0o700)
        self.work = ROOT / ".wippy/owner-journey-work" / self.scratch.name
        self.work.mkdir(parents=True, mode=0o700)
        self.state, self.folder = self.work / "state", self.work / "project"
        self.folder.mkdir()
        (self.work / "tmp").mkdir()
        self.steps, self.current, self.ui = [], None, None
        self.owners, self.secondary = [], None
        self.peer_state, self.peer_folder = None, None
        self.current_action = ""
        self.approvals, self.annoyances, self.granted = {}, [], set()
        self.start_logs = set()
        self.baseline_apps = []
        self.environment = {name: value for name, value in os.environ.items()
                            if name not in STATE_ENVIRONMENT | {"BEE_RUNTIME", "WIPPY_REGISTRY", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"}
                            and not re.search(r"API_KEY|ACCESS_TOKEN|AUTH_TOKEN", name)}
        self.subscription_home = self.environment.get("HOME", str(Path.home()))
        self.fixture_home = self.work / "home"
        self.fixture_home.mkdir()
        fixture_login = self.fixture_home / ".claude"
        fixture_login.mkdir(mode=0o700)
        (fixture_login / ".credentials.json").write_text('{"fixture":true}\n')
        (fixture_login / ".credentials.json").chmod(0o600)
        self.environment.update(HOME=str(self.fixture_home), XDG_CONFIG_HOME=str(self.fixture_home / ".config"), TERM="xterm-256color", TMPDIR=str(self.work / "tmp"))
        self.original_path = self.environment.get("PATH", "/usr/bin:/bin")
        self.stub_bin = self.folder / "bin"
        self.stub_bin.mkdir()
        stub = self.stub_bin / "claude"
        compiled = subprocess.run(["go", "build", "-o", str(stub),
                                   str(ROOT / "tests/fixtures/owner_journey/claude.go")],
                                  env={**self.environment, "HOME": self.subscription_home,
                                       "GOWORK": "off", "GOTOOLCHAIN": "go1.27.0",
                                       "CGO_ENABLED": "0", "GOOS": "linux"}, capture_output=True, text=True)
        require(compiled.returncode == 0, f"journey fixture compiler EXIT {compiled.returncode}: " + compiled.stderr)
        stub.chmod(0o755)
        self.environment["PATH"] = str(self.stub_bin) + ":" + self.original_path
        self.ready = False
        self.desktop_failure = "desktop has not started"
        self.hub = None

    def frame(self, name, ui=None):
        ui = ui or self.ui
        path = self.scratch / f"{self.current.number:02d}-{name}.frame.txt"
        # Raw PTY streams and provider homes never enter evidence.
        path.write_text((ui.text() if ui else "No presenter: " + self.current.cause) + "\n")
        self.current.frames.append(str(path))
        return path

    def observe(self, ui):
        if not self.current:
            return
        self.observe_approvals(ui.state)
        if ui.state == self.state and self.current.number == 1:
            for log in set(self.state.glob("owner-*.log")) - self.start_logs:
                for line in log.read_text(errors="replace").splitlines():
                    match = START_FAILURE.search(line)
                    if match:
                        raise JourneyFailure(match.group(0))
            match = START_FAILURE.search(ui.text())
            if match:
                raise JourneyFailure(match.group(0))

    def observe_approvals(self, state):
        if not table_exists(state, "approvals.db", "bee_approval_requests"):
            return
        for row in rows(state, "approvals.db", "SELECT approval_id,owner_node,requester_id,request_kind,proposal_json,prompt_json,state,decision,expires_at FROM bee_approval_requests"):
            identity = (str(state), row["approval_id"])
            if identity in self.approvals:
                if row["decision"] == "approved":
                    self.granted.add(self.approvals[identity]["scope"])
                continue
            # Baseline rows are history, not prompts raised by this journey.
            if identity in getattr(self, "baseline_approvals", set()):
                continue
            proposal, prompt = json.loads(row["proposal_json"]), json.loads(row["prompt_json"])
            scope = json.dumps(proposal, sort_keys=True)
            record = {"step": self.current.number, "owner_node": row["owner_node"], "approval_id": row["approval_id"],
                      "subject": row["requester_id"], "what": prompt, "scope": scope,
                      "duration": row["expires_at"], "already_granted": scope in self.granted, "action": self.current_action}
            self.approvals[identity] = record
            self.current.approvals += 1
            problems = []
            if scope in self.granted:
                problems.append("scope already granted is requested again")
            if self.current.number == 2:
                problems.append("routine launcher/open/read action asks for elevation")
            same_action = [item for item in self.approvals.values() if item.get("action") == self.current_action and item["step"] == self.current.number and item is not record]
            if same_action and self.current_action:
                problems.append("one person action produced separate decisions")
            prompt_text = prompt.get("text", "") if isinstance(prompt, dict) else ""
            for field_name, pattern in (
                ("subject", r"Bee|agent|application|component|subject|namespace"),
                ("capability", r"allow|create|read|write|apply|publish|start|capability"),
                ("scope", r"scope|namespace|workspace|network|component|folder|path"),
                ("duration", r"until revoked|once|one operation|for \d+|expires|duration")):
                if not re.search(pattern, prompt_text, re.I):
                    problems.append("approval prompt does not state " + field_name)
            if len(prompt_text) > 1600 or len(prompt_text.splitlines()) > 12:
                problems.append("approval prompt exceeds one short screen")
            for problem in problems:
                self.annoyance(problem, record)

    def annoyance(self, cause, record):
        item = {"step": self.current.number, "cause": cause, "approval_id": record.get("approval_id", "person-ui")}
        if item not in self.annoyances:
            self.annoyances.append(item)
            self.current.annoyances.append(cause)

    def run_step(self, number, title, action, desktop=True):
        self.current_action = title
        self.current = Step(number, title)
        self.steps.append(self.current)
        started = time.monotonic()
        try:
            if desktop:
                require(self.ready and self.ui is not None and self.ui.process.poll() is None,
                        "desktop unavailable: " + self.desktop_failure)
            action()
            self.current.status = "PASS"
            if self.current.cause == "not reached":
                self.current.cause = "asserted rendered frames and owner state"
        except (AssertionError, OSError, ValueError, sqlite3.Error, subprocess.SubprocessError, StopIteration) as error:
            self.current.cause = str(error) or type(error).__name__
            if number == 1 or self.ready and (self.ui is None or self.ui.process.poll() is not None):
                self.desktop_failure = self.current.cause
        finally:
            try:
                self.observe_approvals(self.state)
                self.frame("result")
                snapshot = {"applications": [{"definition": app["definition_id"], "instance": app["instance_id"]}
                                             for app in applications(self.state)],
                            "sessions": [{name: item[name] for name in ("session_ref", "thread_id", "title", "state")}
                                         for item in sessions(self.state)], "events": json.loads(progress(self.state)),
                            "owner_pids": live_owners(self.binary, self.state)}
                (self.scratch / f"{number:02d}-owner-state.json").write_text(json.dumps(snapshot, indent=2) + "\n")
            except (OSError, sqlite3.Error, ValueError) as error:
                self.current.status = "FAIL"
                self.current.cause += "; evidence: " + str(error)
            if self.current.annoyances:
                self.current.status = "FAIL"
                self.current.cause += "; " + "; ".join(self.current.annoyances)
            self.current.seconds = time.monotonic() - started
            print(f"{number:2d} {self.current.status} {self.current.seconds:.3f}s {title}: {self.current.cause}", flush=True)
            self.report()

    def report(self):
        lines = [f"Bee: {self.binary}", f"Source (read-only): {self.source}", f"Isolated state: {self.state}",
                 "STEP | PASS/FAIL | SECONDS | APPROVALS | JOURNEY / CAUSE | EVIDENCE"]
        for step in self.steps:
            lines.append(f"{step.number:02d} | {step.status} | {step.seconds:.3f} | {step.approvals} | {step.title}: {step.cause.replace(chr(10), ' / ')} | " + ", ".join(step.frames))
        lines += ["", "Approval prompts (subject, capability/scope, duration, previous grant):"]
        lines.extend(json.dumps(row, sort_keys=True) for row in self.approvals.values())
        lines += ["", "Approval annoyances:"] + [json.dumps(row, sort_keys=True) for row in self.annoyances]
        text = "\n".join(lines) + "\n"
        (self.output / "report.txt").write_text(text)
        (self.scratch / "report.txt").write_text(text)
        (self.scratch / "results.json").write_text(json.dumps([vars(step) for step in self.steps], indent=2) + "\n")
        return text

    def command(self, arguments, state=None, folder=None):
        # Bound is a CLI acknowledgement hang diagnostic, never an outcome oracle.
        try:
            result = subprocess.run([str(self.binary), "--state", str(state or self.state), *arguments],
                                    cwd=folder or self.folder, env=self.environment, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=self.hang_seconds)
        except subprocess.TimeoutExpired as error:
            raise JourneyFailure(f"CLI acknowledgement hang bound ({self.hang_seconds:g}s): {' '.join(arguments[:2])}") from error
        require(result.returncode == 0, f"bee {' '.join(arguments[:2])} EXIT {result.returncode}: {result.stdout}{result.stderr}")
        return result.stdout

    def attach(self):
        self.ui = JourneyDesktop(self, self.folder, self.state, self.environment)
        self.ui.wait(" BEE ")
        self.ui.resize(160, 48)
        self.ui.wait_until(lambda: bool(live_owners(self.binary, self.state)), "owner admission")
        pids = live_owners(self.binary, self.state)
        require(len(pids) == 1, f"expected one owner, found {pids}")
        owner = hold_owner(pids[0], self.binary, self.state)
        require(owner is not None, "owner exited before identity could be held")
        self.owners.append(owner)
        self.ready = True

    def launch(self, label, heading, groups=()):
        self.ui.open_start()
        for group in groups:
            self.ui.choose(group)
        require(any(label + " " in row and "│" in row for row in self.ui.screen.display),
                f"launcher does not expose {label}; visible: {self.ui.text()}")
        self.ui.choose(label)
        self.ui.wait(heading)
        self.frame(label.lower().replace(" ", "-"))

    def click(self, label, containing=None):
        for y, line in enumerate(self.ui.screen.display, 1):
            if label in line and (not containing or containing in line):
                x = line.index(label) + 1
                self.ui.mouse(0, x, y)
                self.ui.mouse(0, x, y, True)
                return
        raise JourneyFailure(f"rendered control {label!r} is missing")

    def start(self):
        manifest = safe_copy(self.source, self.state)
        (self.scratch / "copy.json").write_text(json.dumps(manifest, indent=2) + "\n")
        self.baseline_apps = applications(self.state)
        self.baseline_approvals = set()
        if table_exists(self.state, "approvals.db", "bee_approval_requests"):
            for row in rows(self.state, "approvals.db", "SELECT approval_id,proposal_json,decision FROM bee_approval_requests"):
                self.baseline_approvals.add((str(self.state), row["approval_id"]))
                if row["decision"] == "approved":
                    self.granted.add(json.dumps(json.loads(row["proposal_json"]), sort_keys=True))
        self.start_logs = set(self.state.glob("owner-*.log"))
        self.attach()
        require((self.state / "credentials.db").exists(), "Bee did not create a fresh credential store")
        retained = applications(self.state)
        retained_report = []
        for before in self.baseline_apps:
            identity = before.get("instance_id")
            require(any(app.get("instance_id") == identity for app in retained), f"retained application {identity} was lost: {before.get('definition_id')}")
            window = before.get("window") or {}
            title = window.get("title")
            require(bool(title), f"retained application {identity} has no rendered window title in its owner checkpoint")
            self.ui.wait(title)
            self.click(title)
            self.frame("retained-" + str(len(retained_report)))
            failure = FAILURE.search(self.ui.text())
            retained_report.append({"definition": before["definition_id"], "instance": identity,
                                    "title": title, "outcome": failure.group(0) if failure else "rendered retained view"})
        (self.scratch / "retained-applications.json").write_text(json.dumps(retained_report, indent=2) + "\n")
        require(not any(row["outcome"] != "rendered retained view" for row in retained_report),
                "retained application failures: " + json.dumps(retained_report))
        self.frame("desktop")

    def open_apps(self):
        self.launch("Sessions", "SESSIONS")
        # Apps is the launcher group; it must render even on an empty state.
        self.ui.open_start()
        self.ui.choose("Apps")
        self.frame("apps-launcher")
        self.ui.key(b"\x1b")
        self.launch("Settings", "BEE SETTINGS", ("Settings/Help",))
        self.click("About", "Themes")
        self.ui.wait("BEE SETTINGS · ABOUT")
        self.ui.wait("Live Bee packs")
        self.frame("about")
        self.launch("Needs you", "NEEDS YOU")
        self.launch("Modules", "MODULES", ("Apps", "Advanced"))
        retained = applications(self.state)
        require(bool(retained), "launcher applications were not checkpointed by workspace owner")

    def choose_agent(self, provider="Claude Code", docker=False):
        self.current_action = f"start {provider} on {'Docker' if docker else 'native'}"
        if "Conversation ·" in self.ui.text() or "NEW SESSION" in self.ui.text():
            self.ui.key(b"\x1b")
        elif "Workspace:" not in self.ui.text() or "SESSIONS" not in self.ui.screen.display[1]:
            self.launch("Sessions", "SESSIONS")
        self.ui.wait("Workspace:")
        self.ui.wait("N New session")
        self.ui.key(b"n")
        self.ui.wait("NEW SESSION")
        self.ui.wait_until(lambda: "Loading agents…" not in self.ui.text() and "Enter Open" in self.ui.text(), "agent catalog ready")
        if not any(provider in line for line in self.ui.screen.display[3:-5]):
            self.ui.key(b"u")
            self.ui.wait_until(lambda: "Loading agents…" not in self.ui.text() and "Hide unavailable" in self.ui.text(), "unavailable agent catalog")
        require(any(provider in line for line in self.ui.screen.display[3:-5]),
                f"Sessions catalog has no {provider}: {self.ui.text()}")
        self.click(provider)
        require("Unavailable" not in self.ui.text(), f"{provider} readiness refused: {self.ui.text()}")
        self.frame("provider-selected")
        if docker:
            self.ui.key(b"e")
            self.ui.wait_until(lambda: "CUSTOMIZE COPY" in self.ui.text() or "EDIT AGENT PROFILE" in self.ui.text(), "profile editor")
            self.click("Name:")
            profile_title = "Journey " + provider + " Docker"
            self.ui.key(b"\x15" + profile_title.encode())
            self.click("Placement:")
            # The first choice makes the definition default explicit; the
            # second selects Docker from this driver's two admitted placements.
            self.ui.key(b"\x1b[C\x1b[C")
            self.ui.wait("bee.placement.docker.profiles:coding")
            self.frame("docker-profile")
            self.ui.key(b"\x13")
            self.ui.wait("NEW SESSION")
            self.ui.wait_until(lambda: "Loading agents…" not in self.ui.text(), "saved Docker profile catalog")
            if "U Show unavailable" in self.ui.text():
                self.ui.key(b"u")
                self.ui.wait("U Hide unavailable")
                self.ui.wait_until(lambda: "Loading agents…" not in self.ui.text(), "saved profile readiness result")
            require(profile_title in self.ui.text(), "saved Docker profile is absent from the Sessions catalog")
            self.click(profile_title)
            if "Unavailable" in self.ui.text():
                reason = next((line.strip() for line in self.ui.screen.display if "Unavailable ·" in line), "no readiness cause was rendered")
                raise JourneyFailure("saved Docker profile unavailable: " + reason)
        prior = {item["session_ref"] for item in sessions(self.ui.state)}
        self.ui.key(b"\r")
        self.ui.wait_until(lambda: "Ready for work" in self.ui.text() or "Unavailable" in self.ui.text() or "Setup:" in self.ui.text() or "INVALID:" in self.ui.text() or "START_FAILED:" in self.ui.text(), "session admission")
        require("Ready for work" in self.ui.text(), f"{provider} session was not admitted: {self.ui.text()}")
        new = [item for item in sessions(self.ui.state) if item["session_ref"] not in prior]
        require(len(new) == 1, f"session admission did not persist exactly one session: {len(new)}")
        return new[0]

    def turn(self, prompt, expected, docker=False, provider="Claude Code", fixture=False, require_image_preparation=False):
        if self.environment["PATH"] == self.original_path:
            self.verify_subscription(provider)
        session = self.choose_agent(provider, docker)
        prior_frames = len(self.ui.observed_frames)
        gate = self.work / "stub-release"
        gate_fd = None
        if fixture:
            if not gate.exists():
                os.mkfifo(gate, 0o600)
            gate_fd = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
            prompt += " JOURNEY_GATE=" + str(gate)
        self.ui.key(b"\x1b[200~" + prompt.encode() + b"\x1b[201~")
        self.ui.key(b"\r")
        work = []
        def settled():
            nonlocal work
            self.decide_pending()
            work = rows(self.state, "threads.db", "SELECT work_ref,phase,result_json FROM bee_session_work WHERE session_ref=? ORDER BY sequence", (session["session_ref"],))
            return bool(work) and work[-1]["phase"] == "settled"
        if fixture:
            try:
                def running():
                    if settled():
                        raise JourneyFailure("stub work settled before placement running: " + str(work[-1]["result_json"]))
                    return "working" in self.ui.text() and table_exists(self.state, "placement.db", "bee_placement_attempts") and bool(rows(self.state, "placement.db",
                        "SELECT attempt_id FROM bee_placement_attempts WHERE session_ref=? AND execution_state='running'", (session["session_ref"],)))
                self.ui.wait_until(running, "rendered working and placement running acknowledgement")
                self.frame("native-running")
                os.write(gate_fd, b"release\n")
            finally:
                os.close(gate_fd)
        self.ui.wait_until(settled, "owner work settlement")
        result = json.loads(work[-1]["result_json"])
        self.frame("work-settled")
        require(expected in json.dumps(result), f"{provider} {'Docker' if docker else 'native'} work settled with {json.dumps(result)}")
        self.ui.wait(expected)
        seen = ["\n".join(frame) for frame in self.ui.observed_frames[prior_frames:]]
        require(any("working" in frame or "starting" in frame or "running" in frame for frame in seen), "no rendered starting/running/working state was observed")
        if docker:
            require(any("starting" in frame.lower() for frame in seen), "Docker placement never rendered starting")
        if require_image_preparation:
            require(any("Preparing Docker runtime image" in frame for frame in seen), "Docker placement never rendered runtime image preparation progress")
        self.close_session(session)
        return session

    def close_session(self, session):
        self.ui.key(b"\x18")
        self.ui.wait("Close session?")
        self.frame("stop-confirmation")
        self.ui.key(b"\r")
        self.ui.wait("Closed · history remains available")
        if table_exists(self.state, "placement.db", "bee_placement_attempts"):
            self.ui.wait_until(lambda: not rows(self.state, "placement.db",
                "SELECT attempt_id FROM bee_placement_attempts WHERE session_ref=? AND (execution_state!='exited' OR exit_source IS NULL)", (session["session_ref"],)),
                "independently observed placement EXIT")
        require(any(item["session_ref"] == session["session_ref"] and item["state"] == "closed" for item in sessions(self.state)), "stop did not close the owner session")

    def native_stub(self):
        self.turn("Return the deterministic journey marker.", STUB_MARKER, fixture=True)

    def docker_session(self):
        before = {item["session_ref"] for item in sessions(self.state)}
        try:
            self.turn("Reply with the deterministic journey marker", STUB_MARKER, docker=True, require_image_preparation=True)
        except JourneyFailure as error:
            # Step 4 permits only a truthful start_failed with the daemon cause.
            cause = str(error)
            if "start_failed" in cause and re.search(r"daemon|docker.sock|Cannot connect|connection refused", cause, re.I):
                self.current.cause = "precise Docker start_failed: " + cause
                self.frame("docker-start-failed")
                admitted = [item for item in sessions(self.state) if item["session_ref"] not in before]
                require(len(admitted) == 1, "Docker start_failed did not identify one owner session: " + cause)
                try:
                    self.close_session(admitted[0])
                except JourneyFailure as stopped:
                    raise JourneyFailure(cause + "; stopping the failed Docker session: " + str(stopped)) from stopped
                return
            raise

    def restart(self):
        before_apps = applications(self.state)
        checkpoints = {"before_detach": before_apps}
        before_sessions = {item["session_ref"] for item in sessions(self.state)}
        self.ui.quit()
        self.ui.close()
        self.ui = None
        checkpoints["after_detach"] = applications(self.state)
        self.command(["stop"])
        checkpoints["after_stop"] = applications(self.state)
        require(not live_owners(self.binary, self.state), "bee stop acknowledged while owner remained")
        self.attach()
        after_apps = applications(self.state)
        checkpoints["after_attach"] = after_apps
        evidence = {stage: [{field: app.get(field) for field in ("definition_id", "instance_id", "restart_policy")}
                            for app in apps] for stage, apps in checkpoints.items()}
        (self.scratch / f"{self.current.number:02d}-restart-checkpoints.json").write_text(json.dumps(evidence, indent=2) + "\n")
        for app in before_apps:
            require(any(item.get("instance_id") == app.get("instance_id") for item in after_apps), f"restart lost retained app {app.get('definition_id')}")
        require(before_sessions <= {item["session_ref"] for item in sessions(self.state)}, "restart lost session history")
        self.launch("Sessions", "SESSIONS")
        self.launch("Settings", "BEE SETTINGS", ("Settings/Help",))
        self.frame("restarted-history")

    def ensure_hub(self):
        if self.hub:
            return
        self.hub = LocalHub(self.binary, self.scratch, self.environment, self.hang_seconds)
        self.environment["WIPPY_REGISTRY"] = self.hub.url
        self.restart()

    def update_plan(self):
        self.ensure_hub()
        self.launch("Settings", "BEE SETTINGS", ("Settings/Help",))
        self.click("About", "Themes")
        self.ui.wait("BEE SETTINGS · ABOUT")
        self.frame("update-entry-location")
        self.launch("Modules", "MODULES", ("Apps", "Advanced"))
        self.click("Installed", "Installed")
        self.ui.wait("Update Bee")
        self.ui.key(b"u")
        self.ui.wait_until(lambda: any(label in self.ui.text() for label in ("Ready for confirmation", "PLAN:", "INVALID:", "Missing:", "ERROR:", "needs a newer Bee binary")), "Update Bee plan or exact refusal")
        self.frame("update-plan")
        require("Ready for confirmation" in self.ui.text(), "Update Bee plan refused: " + self.ui.text())

    def cases(self, actions):
        failures = []
        for name, action in actions:
            started = time.monotonic()
            self.current_action = name
            try:
                action()
                outcome = "PASS"
            except (AssertionError, OSError, ValueError, sqlite3.Error, subprocess.SubprocessError, StopIteration) as error:
                outcome = str(error) or type(error).__name__
                failures.append(name + ": " + outcome)
            path = self.scratch / f"{self.current.number:02d}-subcases.txt"
            with path.open("a") as output:
                output.write(f"{name} | {time.monotonic() - started:.3f}s | {outcome}\n")
            self.frame("subcase-" + name.lower().replace(" ", "-"))
        require(not failures, "; ".join(failures))

    def verify_subscription(self, provider):
        executable = shutil.which("claude" if provider == "Claude Code" else "codex", path=self.original_path)
        require(executable is not None, provider + " executable is absent from OS-user PATH")
        status_args = [executable, "auth", "status"] if provider == "Claude Code" else [executable, "login", "status"]
        status = subprocess.run(status_args, env=self.environment, cwd=self.folder,
                                capture_output=True, text=True, timeout=self.hang_seconds)
        require(status.returncode == 0, provider + f" login-status EXIT {status.returncode}; subscription is not ready")
        if provider == "Claude Code":
            metadata = json.loads(status.stdout)
            require(isinstance(metadata, dict), "Claude login-status is not a metadata object")
            method = metadata.get("authMethod")
            require(method in ("claude.ai", "oauth"), "Claude login-status reports authentication method " + str(method) + "; subscription required")
        else:
            require("ChatGPT" in status.stdout + status.stderr, "Codex login-status does not report a ChatGPT subscription")

    def subscriptions(self):
        self.ui.quit()
        self.ui.close()
        self.ui = None
        self.command(["stop"])
        self.environment.update(PATH=self.original_path, HOME=self.subscription_home,
                                XDG_CONFIG_HOME=str(Path(self.subscription_home) / ".config"))
        self.attach()
        home = Path(self.subscription_home)
        def real_turn(provider, docker):
            login = home / (".claude/.credentials.json" if provider == "Claude Code" else ".codex/auth.json")
            require(login.is_file(), provider + " subscription login evidence absent (existence only; no credential file read)")
            self.turn("Reply exactly: " + MARKER, MARKER, docker=docker, provider=provider)
        actions = [("Claude native subscription", lambda: real_turn("Claude Code", False)),
                   ("Claude Docker subscription", lambda: real_turn("Claude Code", True))]
        if (home / ".codex/auth.json").is_file():
            actions += [("Codex native subscription", lambda: real_turn("Codex", False)),
                        ("Codex Docker subscription", lambda: real_turn("Codex", True))]
        else:
            (self.scratch / "08-codex-login-existence.txt").write_text("Codex subscription login evidence absent; conditional provider does not apply.\n")
        self.cases(actions)

    def edit_mode(self, namespace):
        self.launch("Settings", "BEE SETTINGS", ("Settings/Help",))
        self.click("Edit mode", "Themes")
        self.ui.wait("BEE SETTINGS · EDIT MODE")
        self.ui.key(b"e")
        self.ui.wait("Enable edit mode")
        self.ui.key(namespace.encode() + b" --for 30m\r")
        self.ui.wait("Confirm edit mode")
        self.record_person_prompt("Edit namespaces " + namespace, self.ui.text())
        self.ui.key(b"\t\r")
        self.ui.wait_until(lambda: any(message in self.ui.text() for message in ("Edit mode refused:", "Edit mode failed:", "Edit mode cancelled")) or "enabled" in self.ui.text().lower(),
                           "host edit-mode grant or exact refusal")
        self.frame("edit-mode-outcome")
        for label in ("Edit mode refused:", "Edit mode failed:"):
            if label in self.ui.text():
                notice = next(line.strip().split("  ", 1)[0] for line in self.ui.screen.display if label in line)
                raise JourneyFailure("host edit-mode grant: " + notice)
        require("Edit mode cancelled" not in self.ui.text(), "host edit-mode confirmation was cancelled")
        self.granted.add("Edit namespaces " + namespace)

    def self_edit(self):
        def component():
            self.edit_mode("bee.desktop")
            pid = live_owners(self.binary, self.state)
            marker = "OWNER JOURNEY CORE"
            self.turn("Read Bee's authoring guide. Use the Settings-granted exact bee.desktop namespace to edit "
                      "only the Lua source of bee.desktop:model (library.lua) through governed base-component publication. "
                      "Preserve its id, kind, imports and native modules. Keep ns.definition and package version metadata unchanged; "
                      "the delivery artifact version is separate from registry package metadata. "
                      "Add a visible desktop window label OWNER JOURNEY CORE using desktop-owned layout or title values. "
                      "This is a base component edit: do not create an application. Freeze, publish and stage its exact "
                      "candidate for person review; do not apply. Return its candidate or Bee's precise refusal.", marker, provider=self.author_provider)
            self.activate_staged("bee.desktop")
            # The terminal presenter follows its documented explicit F12 reload.
            self.ui.key(b"\x1b[24~")
            self.ui.wait(marker)
            self.frame("component-live-label")
            require(live_owners(self.binary, self.state) == pid, "component self-edit replaced owner PID")
            self.restart()
            self.ui.wait(marker)
            self.frame("component-restarted-label")
            self.remove_edit_mode()
            self.ui.key(b"\x1b[24~")
            self.click("About", "Themes")
            self.ui.wait("Website")
            self.ui.wait_until(lambda: marker not in self.ui.text(), "component removal rendered")
            require(marker not in self.ui.text(), "component removal did not restore the desktop label")
        def hub_update():
            self.update_plan()
            pid = live_owners(self.binary, self.state)
            self.ui.key(b"\r")
            self.ui.wait("MODULES  CONFIRM")
            self.record_person_prompt("Update Bee from isolated Hub", self.ui.text())
            self.ui.key(b"\r")
            self.ui.wait("MODULES  RESULT")
            self.frame("hub-apply-result")
            require("Receipt state: complete" in self.ui.text(), "local Hub apply failed: " + self.ui.text())
            require(live_owners(self.binary, self.state) == pid, "Hub apply replaced owner PID")
            self.ui.key(b"\x17")
            self.ui.wait(self.hub.marker)
            self.frame("hub-updated-open-about")
            self.restart()
            self.click("About", "Themes")
            self.ui.wait(self.hub.marker)
        self.cases([("agent Bee component self-edit", component), ("local Hub live update", hub_update)])

    def authored_change(self):
        self.edit_mode("bee.settings.app")
        self.launch("Settings", "BEE SETTINGS", ("Settings/Help",))
        self.click("About", "Themes")
        self.ui.wait("BEE SETTINGS · ABOUT")
        marker = "OWNER JOURNEY OVERLAY"
        self.frame("original-about")
        pid = live_owners(self.binary, self.state)
        brief = ("Use Bee's scoped overlay/governance authoring tool and approved publication path. "
                 "Read its guide. Author an overlay that changes the visible Website label in built-in Settings/About. " +
                 f"Set the label to {marker}. Freeze, publish and stage the exact candidate for this workspace. "
                 "Do not apply, do not write registry or credentials; the person will approve in Bee. "
                 "Return the candidate identity, or the precise refusal from Bee if this path is unavailable.")
        self.turn(brief, marker, provider=self.author_provider)
        self.activate_staged("bee.settings.app")
        self.launch("Settings", "BEE SETTINGS", ("Settings/Help",))
        self.ui.wait(marker)
        require(live_owners(self.binary, self.state) == pid, "authoring change replaced owner PID")
        self.restart()
        self.click("About", "Themes")
        self.ui.wait(marker)
        self.remove_edit_mode()
        self.click("About", "Themes")
        self.ui.wait("Website")
        require(marker not in self.ui.text(), "removing overlay did not restore original About label")

    def activate_staged(self, source_workspace):
        self.launch("Overlays", "OVERLAYS", ("Apps", "Advanced"))
        self.click("Available", "Staged")
        self.ui.key(b"r")
        self.ui.wait(source_workspace)
        self.click(source_workspace)
        self.ui.key(b"\r")
        self.ui.wait("Read review")
        self.click("Staged", "Available")
        self.ui.wait(source_workspace)
        self.click(source_workspace)
        self.ui.key(b"\r")
        self.ui.wait("Preflight")
        require("blocked" not in self.ui.text().lower(), "Governance preflight refused: " + self.ui.text())
        self.ui.key(b"\r")
        self.ui.wait_until(lambda: "Activation approval_bound" in self.ui.text()
                           or governance_failure(self.ui.text()),
                           "governed approval preparation acknowledgement or refusal")
        require("Activation approval_bound" in self.ui.text(), "Governance preparation refused: " + self.ui.text())
        self.launch("Needs you", "NEEDS YOU")
        self.approve()
        self.launch("Overlays", "OVERLAYS", ("Apps", "Advanced"))
        if not re.search(r"\bApply\b", self.ui.text()):
            self.ui.key(b"t")
            self.ui.wait("Apply")
        self.click("Apply")
        self.ui.wait_until(lambda: "Activation settled" in self.ui.text() or governance_failure(self.ui.text()),
                           "governed activation outcome or explicit owner refusal")
        require(re.search(r"(?m)^\s*(?:Activation\s+)?settled\s+(?:·\s*)?applied(?:\s|$)", self.ui.text()),
                "governed activation did not settle as applied: " + self.ui.text())

    def remove_edit_mode(self):
        self.launch("Settings", "BEE SETTINGS", ("Settings/Help",))
        self.click("Edit mode", "Themes")
        self.ui.wait("Edit mode")
        self.ui.key(b"d")
        self.ui.wait("Disable")
        self.record_person_prompt("Remove overlay", self.ui.text())
        self.ui.key(b"\t\r")
        self.ui.wait_until(lambda: any(message in self.ui.text() for message in ("Disabled edit mode for this workspace", "Edit mode is disabled for this workspace"))
                           or any(label in self.ui.text() for label in ("Edit mode refused:", "Edit mode failed:")),
                           "host edit-mode removal acknowledgement or exact refusal")
        require(any(message in self.ui.text() for message in ("Disabled edit mode for this workspace", "Edit mode is disabled for this workspace")), "host edit-mode removal: " + self.ui.text())

    def record_person_prompt(self, subject, text):
        # An Inbox detail is the rendered presentation of its existing request,
        # not another prompt. Person-only confirmations have no approval row.
        for record in self.approvals.values():
            if record["step"] == self.current.number and record.get("approval_id") and record["approval_id"] in text:
                record["frame"] = str(self.frame("approval-short-screen"))
                return
        pending = [record for record in self.approvals.values()
                   if record["step"] == self.current.number and record.get("action") == self.current_action]
        if subject == "governed candidate" and len(pending) == 1:
            pending[0]["frame"] = str(self.frame("approval-short-screen"))
            return
        self.current.approvals += 1
        identity = ("person-ui", str(len(self.approvals)))
        scope = subject if subject.startswith("Edit namespaces ") else text
        duration_match = re.search(r"--for\s+\S+|until revoked|once|one operation|duration[^\n│]*|expires[^\n│]*", text, re.I)
        duration = duration_match.group(0).strip() if duration_match else "not stated"
        self.approvals[identity] = {"step": self.current.number, "subject": subject, "what": text,
                                    "scope": scope, "duration": duration, "already_granted": scope in self.granted, "action": subject,
                                    "frame": str(self.frame("person-approval-" + str(len(self.approvals))))}
        if scope in self.granted:
            self.annoyance("scope already granted is requested again", self.approvals[identity])
        for field_name, pattern in (
                ("subject", "subject|application|component|namespace|workspace|node"),
                ("capability", "allow|capability|action|update|edit|enable|disable|remove|observe|control"),
                ("scope", "scope|namespace|workspace|component"),
                ("duration", "duration|expires|minutes|hours|once")):
            if not re.search(pattern, text, re.I):
                self.annoyance("person confirmation does not state " + field_name, self.approvals[identity])

    def decide_pending(self):
        pending = rows(self.ui.state, "approvals.db", "SELECT approval_id FROM bee_approval_requests WHERE state='pending'")
        pending = [item for item in pending if (str(self.ui.state), item["approval_id"]) not in self.baseline_approvals]
        if not pending:
            return
        self.launch("Needs you", "NEEDS YOU")
        for item in pending:
            self.approve(item["approval_id"])
        self.ui.key(b"\x17")
        self.ui.wait("SESSION")

    def approve(self, approval_id=None):
        if "Allow once" not in self.ui.text():
            self.ui.wait("pending   ")
            self.click("pending   ")
            self.ui.key(b"\r")
        self.ui.wait("Allow once")
        self.frame("approval-detail")
        text = self.ui.text()
        self.record_person_prompt("governed candidate", text)
        require("Allow once" in text, "Inbox does not expose the requested decision")
        self.ui.key(b"a")
        if approval_id:
            self.ui.wait_until(lambda: bool(rows(self.ui.state, "approvals.db",
                "SELECT approval_id FROM bee_approval_requests WHERE approval_id=? AND decision='approved'", (approval_id,))),
                "exact owner approval decision")
        self.ui.wait_until(lambda: "approved" in self.ui.text().lower(), "owner approval decision")
        self.frame("approval-decided")

    def control_hive_workspace(self):
        # Leave the read-only viewer before asking the owning host for control.
        # Hive membership does not enroll remote approval feeds in the local inbox.
        self.ui.key(b"\x1bq")
        self.ui.wait("HIVE MANAGER")
        self.ui.key(b"c")
        self.ui.wait("Control this workspace here?")
        self.record_person_prompt("Control node 2 workspace", self.ui.text())
        self.ui.key(b"\t\r")
        self.ui.wait_until(lambda: "Alt+Q leave" in self.ui.text() or "Hive Manager fail" in self.ui.text()
                           or "Remote desktop ended:" in self.ui.text(), "controlled peer desktop or observed viewer failure")
        if "Alt+Q leave" not in self.ui.text():
            self.ui.resize(640, 48)
            self.ui.wait_until(lambda: "Hive Manager fail" in self.ui.text() or "Remote desktop ended:" in self.ui.text(),
                               "rendered control-view failure")
            self.frame("control-view-failure")
            cause = next(line.strip() for line in self.ui.screen.display
                         if "Hive Manager fail" in line or "Remote desktop ended:" in line)
            raise JourneyFailure("Hive Control: " + cause)
        self.ui.wait("Control")

    def open_remote_inbox(self):
        # F1 belongs to the local presenter; click the controlled desktop's bar.
        for y, line in enumerate(self.ui.screen.display[1:], 2):
            if " BEE " in line and "Needs you" in line:
                x = line.index("Needs you") + 1
                self.ui.mouse(0, x, y)
                self.ui.mouse(0, x, y, True)
                self.ui.wait("NEEDS YOU")
                self.frame("remote-inbox")
                return
        raise JourneyFailure("controlled peer desktop does not expose Needs you")

    def allow_remote_review(self):
        self.ui.key(b"k\r")
        self.ui.wait("Allow once")
        self.frame("remote-approval-detail")
        self.record_person_prompt("governed candidate", self.ui.text())
        self.ui.key(b"a")

    def hive(self):
        folder, state = self.work / "node2-project", self.work / "node2-state"
        self.peer_state, self.peer_folder = state, folder
        folder.mkdir()
        invite = self.work / "hive-invite"  # deliberately never printed or read
        self.command(["hive", "invite", "--out", str(invite)])
        # The CLI accepts the invite as its opaque argument; never retain it in evidence.
        invitation = invite.read_text().strip()
        try:
            self.command(["hive", "join", invitation], state, folder)
        finally:
            invitation = ""
            invite.unlink()
        peer_environment = dict(self.environment, PATH=str(self.stub_bin) + ":" + self.original_path,
                                HOME=str(self.fixture_home), XDG_CONFIG_HOME=str(self.fixture_home / ".config"))
        self.secondary = JourneyDesktop(self, folder, state, peer_environment)
        self.secondary.wait(" BEE ")
        self.secondary.resize(160, 48)
        self.command(["hive", "peers"])
        peer = self.secondary
        peer.wait("SESSIONS")
        peer.key(b"\x1b")
        peer.wait("No applications open")
        secondary_peers = self.command(["hive", "peers"], state, folder)
        node_id = secondary_peers.splitlines()[0].removeprefix("NODE ")
        require(bool(node_id) and "established" in secondary_peers, "node 2 reports no established Hive session")

        def remote_visibility():
            self.launch("Hive Manager", "HIVE MANAGER", ("Apps", "Advanced"))
            self.ui.wait("2 computers")
            self.ui.key(b"t")
            self.ui.wait(node_id)
            self.click(node_id)
            self.ui.key(b"\r")
            self.ui.wait("served")
            self.ui.key(b"o")
            self.ui.wait("Observe this workspace here?")
            self.record_person_prompt("Observe node 2 workspace", self.ui.text())
            self.ui.key(b"\t\r")
            self.ui.wait_until(lambda: any(message in self.ui.text() for message in
                ("No applications open", "Remote desktop ended:", "Remote desktop closed")),
                "remote empty desktop or observed viewer EXIT")
            if "No applications open" not in self.ui.text():
                # Widen the footer to retain the owner's full EXIT cause.
                self.ui.resize(640, 48)
                self.ui.wait_until(lambda: any(message in self.ui.text() for message in
                    ("Remote desktop ended:", "Remote desktop closed")), "rendered viewer EXIT cause")
                self.frame("remote-viewer-exit")
                cause = next(line.split("↑↓", 1)[0].strip() for line in self.ui.screen.display
                             if "Remote desktop ended:" in line or "Remote desktop closed" in line)
                self.ui.resize(160, 48)
                raise JourneyFailure("Hive viewer EXIT: " + cause)
            self.frame("remote-count-zero-before")
            peer.open_start()
            peer.choose("Apps")
            peer.choose("Terminal")
            peer.wait("Terminal")
            peer.key(b"printf 'OWNER_JOURNEY_NODE_TWO\\n'\r")
            peer.wait("OWNER_JOURNEY_NODE_TWO")
            self.ui.wait("OWNER_JOURNEY_NODE_TWO")
            self.frame("remote-count-one")
            remote_bars = [line for line in self.ui.screen.display[1:] if " BEE " in line]
            require(remote_bars and sum(line.count("▣") for line in remote_bars) == 1,
                    "node 1 remote desktop does not render exactly one live app; expected count 0->1")
            peer.key(b"\x17")
            peer.wait("Close")
            peer.key(b"\t\r")
            peer.wait("No applications open")
            self.ui.wait("No applications open")
            self.frame("remote-count-zero-after")
            remote_bars = [line for line in self.ui.screen.display[1:] if " BEE " in line]
            require(remote_bars and sum(line.count("▣") for line in remote_bars) == 0,
                    "node 1 remote desktop app count did not return 1->0")
            require("established" in self.command(["hive", "peers"]), "live app observation lost its admitted peer session")

        def remote_approval():
            gate = self.work / "hive-approval-release"
            os.mkfifo(gate, 0o600)
            with os.fdopen(os.open(gate, os.O_RDWR | os.O_NONBLOCK), "wb", buffering=0) as release:
                primary = self.ui
                self.ui = peer
                try:
                    session = self.choose_agent()
                    peer.key(("JOURNEY_HIVE_APPROVAL JOURNEY_GATE=" + str(gate) + "\r").encode())
                    peer.wait_until(lambda: "OWNER JOURNEY REVIEW STAGED" in peer.text() or bool(rows(state, "threads.db",
                        "SELECT result_json FROM bee_session_work WHERE session_ref=? AND phase='settled'", (session["session_ref"],))),
                        "native session stages its review or observed work settlement")
                    if "OWNER JOURNEY REVIEW STAGED" not in peer.text():
                        settled = rows(state, "threads.db", "SELECT result_json FROM bee_session_work WHERE session_ref=? AND phase='settled'",
                                       (session["session_ref"],))
                        raise JourneyFailure("native review settled before staging: " + settled[-1]["result_json"])
                    self.launch("Overlays", "OVERLAYS", ("Apps", "Advanced"))
                    peer.key(b"\r")
                    peer.wait("Staged")
                    self.click("Staged", "Available")
                    peer.key(b"\r")
                    peer.wait("Preflight")
                    require("blocked" not in peer.text().lower(), "native review preflight refused: " + peer.text())
                    peer.key(b"\r")
                    peer.wait_until(lambda: bool(rows(state, "approvals.db",
                        "SELECT approval_id FROM bee_approval_requests WHERE state='pending'")), "node 2 native review approval")
                    pending = rows(state, "approvals.db", "SELECT approval_id FROM bee_approval_requests WHERE state='pending'")
                    if not pending:
                        settled = rows(state, "threads.db", "SELECT result_json FROM bee_session_work WHERE session_ref=? AND phase='settled'",
                                       (session["session_ref"],))
                        raise JourneyFailure("native review settled before approval: " + settled[-1]["result_json"])
                    require(len(pending) == 1, f"node 2 raised {len(pending)} pending approvals for one review")
                    approval_id = pending[0]["approval_id"]
                finally:
                    self.ui = primary
                self.control_hive_workspace()
                self.open_remote_inbox()
                self.ui.wait("pending")
                self.allow_remote_review()
                self.ui.wait_until(lambda: bool(rows(state, "approvals.db",
                    "SELECT approval_id FROM bee_approval_requests WHERE approval_id=? AND decision='approved'", (approval_id,))),
                    "node 2 observes node 1 decision")
                self.frame("remote-approval-decided")
                release.write(b"observed exact remote approval\n")
                peer.wait_until(lambda: bool(rows(state, "threads.db",
                    "SELECT work_ref FROM bee_session_work WHERE session_ref=? AND phase='settled'", (session["session_ref"],))),
                    "native fixture completes after the exact remote decision is observed")
                work = rows(state, "threads.db", "SELECT result_json FROM bee_session_work WHERE session_ref=? ORDER BY sequence",
                            (session["session_ref"],))
                require(STUB_MARKER in work[-1]["result_json"], "native Hive approval work settled with " + work[-1]["result_json"])
        self.cases([("Hive live app counts 0 to 1 to 0", remote_visibility),
                    ("Hive remote approval", remote_approval)])
        peer.quit()
        peer.close()
        self.secondary = None
        self.command(["stop"], state, folder)
        require(not live_owners(self.binary, state), "node 2 owner remains after stop")

    def stop(self):
        if self.ready and self.ui and self.ui.process.poll() is None:
            self.ui.quit()
        result = self.command(["stop"])
        require("Bee stopped" in result or "not running" in result, "bee stop gave no stopped acknowledgement: " + result)
        for owner in self.owners:
            require(owner.exited(timeout=self.hang_seconds), "bee stop acknowledged but owner EXIT was not observed")
        require(not live_owners(self.binary, self.state), "an owner process remains for scratch state")
        if self.peer_state:
            peer_result = self.command(["stop"], self.peer_state, self.peer_folder)
            require("Bee stopped" in peer_result or "not running" in peer_result,
                    "node 2 bee stop gave no stopped acknowledgement: " + peer_result)
            require(not live_owners(self.binary, self.peer_state), "node 2 owner remains after bee stop")
            if self.secondary:
                self.secondary.close()
                self.secondary = None
            result += "Node 2: " + peer_result
        self.current.cause = result.strip()

    def cleanup(self):
        errors = []
        def attempt(action):
            try:
                action()
            except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as error:
                errors.append(str(error) or type(error).__name__)
        if self.secondary:
            attempt(self.secondary.close)
        if self.peer_state:
            for pid in live_owners(self.binary, self.peer_state):
                attempt(lambda: stop_owner(hold_owner(pid, self.binary, self.peer_state)))
        if self.ui:
            attempt(self.ui.close)
        for owner in self.owners:
            attempt(lambda: stop_owner(owner))
        for pid in live_owners(self.binary, self.state):
            attempt(lambda: stop_owner(hold_owner(pid, self.binary, self.state)))
        if self.hub:
            attempt(self.hub.close)
        require(self.work.parent == (ROOT / ".wippy/owner-journey-work").resolve(), "scratch cleanup escaped its root")
        attempt(lambda: shutil.rmtree(self.work))
        require(not errors, "cleanup failed: " + "; ".join(errors))

    def run(self, selected_steps=None):
        try:
            self.run_step(1, "copied-state startup and retained applications", self.start, desktop=False)
            if selected_steps is None or 2 in selected_steps:
                self.run_step(2, "launcher Sessions, Apps, Settings/About, Inbox, Modules", self.open_apps)
            if selected_steps is None or 3 in selected_steps:
                self.run_step(3, "native deterministic agent running/output/stop", self.native_stub)
            if selected_steps is None or 4 in selected_steps:
                self.run_step(4, "Docker starting/running or exact daemon start_failed", self.docker_session)
            if selected_steps is None or 5 in selected_steps:
                self.run_step(5, "full owner restart preserves apps and sessions history", self.restart)
            if selected_steps is None or 6 in selected_steps:
                self.run_step(6, "Update Bee plan through Settings/About and Modules", self.update_plan)
            if selected_steps is None or 8 in selected_steps:
                self.run_step(8, "real Claude and available Codex subscriptions, native and Docker", self.subscriptions)
            if selected_steps is None or 9 in selected_steps:
                self.run_step(9, "agent overlay, approval, live About, restart and removal", self.authored_change)
            if selected_steps is None or 10 in selected_steps:
                self.run_step(10, "agent Bee component self-edit and local Hub live update", self.self_edit)
            if selected_steps is None or 11 in selected_steps:
                self.run_step(11, "two-node Hive live counts and remote approval decision", self.hive)
            self.run_step(7, "bee stop observes clean owner EXIT", self.stop, desktop=False)
        finally:
            try:
                self.cleanup()
            except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as error:
                failure = Step(7, "journey process/state cleanup", cause=str(error))
                self.steps.append(failure)
                self.report()
        print(self.report(), end="")
        return 1 if any(step.status == "FAIL" for step in self.steps) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--source-state", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / ".wippy/owner-journey")
    parser.add_argument("--hang-seconds", type=float, default=600, help="no-progress diagnostic bound; never a speed requirement")
    parser.add_argument("--author-provider", choices=("Claude Code", "Codex"), default="Claude Code",
                        help="existing subscription provider for the two owned authoring proofs")
    parser.add_argument("--steps", help="comma-separated journey steps; startup and stop always run")
    args = parser.parse_args()
    require(args.binary.is_file() and os.access(args.binary, os.X_OK), f"BEE_BINARY is not executable: {args.binary}")
    require(args.hang_seconds > 0, "hang bound must be positive")
    require((ROOT / ".wippy").resolve() in args.output.resolve().parents, "evidence and scratch state must be under repository .wippy/")
    selected_steps = {int(value) for value in args.steps.split(",")} if args.steps else None
    require(selected_steps is None or selected_steps <= set(range(1, 12)), "journey steps must be 1 through 11")
    return Journey(args.binary, args.source_state, args.output, args.hang_seconds, args.author_provider).run(selected_steps)


if __name__ == "__main__":
    raise SystemExit(main())
