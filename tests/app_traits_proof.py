"""Real Bee MCP proof using the Hub app and the existing bee-e2e UI driver."""
import argparse
import hashlib
import json
import os
import pty
import threading
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bee", type=Path, required=True)
    parser.add_argument("--e2e", type=Path, required=True)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--installed", action="store_true", help="reuse Progress installed in this isolated proof home")
    args = parser.parse_args()
    sys.path.insert(0, str(args.e2e.resolve()))
    from bee_e2e.journey import Journey
    from bee_e2e.wait import until

    journey = Journey(args.e2e.resolve(), args.run.resolve(), "app-traits", args.bee.resolve(), 120)
    def approve(ui, phrase, approval_id=None):
        pending = [row for row in ui.node.state("approvals")["rows"] if row["state"] == "pending"
                   and phrase in row["prompt_json"] and (approval_id is None or row["approval_id"] == approval_id)]
        assert len(pending) == 1, "approval must name one exact pending request"
        target = pending[0]["approval_id"]
        ui.open("Needs you")
        ui.wait_for("NEEDS YOU")
        until(lambda: re.search(r"\d+ pending · \d+ shown", ui.screen())
              or any(text in ui.screen() for text in ("Approved by you", "Reviewing request", "Denied by you")),
              "approval view finishes loading", 120, ui.screen)
        if not re.search(r"\d+ pending · \d+ shown", ui.screen()):
            ui.press("Escape")
        ui.press("r")
        ui.wait_for(re.compile(r"\d+ pending · \d+ shown"))
        ui.press("PPage")
        ui.press("Enter")
        ui.wait_for(phrase)
        ui.press("NPage")
        ui.wait_for(re.compile(r"\bA Approve\b|\bA Allow once\b", re.I))
        ui.press("a")
        ui.wait_for(re.compile(r"[Aa]pprove.*\?|[Cc]onfirm"))
        ui.press("Enter")
        until(lambda: any(row["approval_id"] == target and row["state"] == "decided" and row["decision"] == "approved"
                          for row in ui.node.state("approvals")["rows"]), "the exact person decision commits", 120, ui.screen)
        return target

    pairing = None
    evidence = {"binary_sha256": hashlib.sha256(args.bee.read_bytes()).hexdigest()}
    try:
        ui = journey.add(config_root=args.run.resolve() / "app-traits/local/home/.config")
        if not args.installed:
            ui.open("Library")
            ui.wait_for("Installed")
            ui.press("Tab")
            ui.wait_for("Nothing is shared with this bee")
            ui.press("/")
            ui.wait_for(re.compile(r"│\s*▏\s*│"))
            ui.type("progress")
            ui.wait_for(re.compile(r"│\s*progress▏\s*│"))
            ui.press("Enter")
            ui.wait_for("Progress")
            ui.press("o")
            ui.wait_for("bee/progress")
            ui.wait_for("Review installation")
            ui.press("i")
            ui.wait_for("Action install")
            ui.press("p")
            ui.wait_for("Ask for approval")
            ui.press("Enter")
            until(lambda: any(row["state"] == "pending" and "progress" in row["prompt_json"].lower()
                              for row in ui.node.state("approvals")["rows"]), "Progress install approval arrives", 120, ui.screen)
            approve(ui, "Install Progress")
            until(lambda: any(row["source_workspace"] == "hub:bee/progress" and row["phase"] == "settled"
                              and row["outcome"] == "applied" for row in ui.node.state("upgrade_applications")["rows"]),
                  "Progress installation settles", 120, ui.screen)
            ui.open("Progress")
            ui.wait_for("PROGRESS")
        evidence["hub_install"] = "bee/progress"
        client_name = "Appux proof " + uuid.uuid4().hex[:8]
        master, slave = pty.openpty()
        captured = []
        def capture():
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                captured.append(chunk.decode(errors="replace"))
        pairing = subprocess.Popen([str(args.bee.resolve()), "mcp", "connect", "--name", client_name],
                                   cwd=ui.node.root, env=ui.node.env, stdin=slave, stdout=slave,
                                   stderr=subprocess.PIPE, text=True)
        os.close(slave)
        reader = threading.Thread(target=capture, daemon=True)
        reader.start()
        def requested_pairing():
            if pairing.poll() is not None:
                _, error = pairing.communicate()
                raise AssertionError("MCP pairing command exited before approval: " + error)
            return any(row["state"] == "pending" and client_name in row["prompt_json"]
                       for row in ui.node.state("approvals")["rows"])
        until(requested_pairing, "MCP pairing approval arrives", 120, ui.screen)
        approve(ui, "Pair external MCP client " + client_name)
        _, error = pairing.communicate(timeout=120)
        reader.join()
        os.close(master)
        assert pairing.returncode == 0, "pairing failed: " + error
        output = "".join(captured).replace("\r\n", "\n")
        token = re.search(r"export BEE_MCP_TOKEN='([^']+)'", output)[1]
        configuration = json.loads(re.search(r"```json\n(.*?)\n```", output, re.S)[1])
        url = configuration["mcpServers"]["bee"]["url"]
        sequence = 0

        def rpc(method, parameters):
            nonlocal sequence
            sequence += 1
            request = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": sequence,
                                               "method": method, "params": parameters}).encode(),
                                             {"Content-Type": "application/json", "Authorization": "Bearer " + token})
            with urllib.request.urlopen(request, timeout=30) as response:
                reply = json.load(response)
            assert "error" not in reply, reply
            return reply["result"]

        def tool(name, arguments):
            return rpc("tools/call", {"name": name, "arguments": arguments})

        def value(reply):
            assert not reply.get("isError"), reply
            structured = reply["structuredContent"]
            assert structured["ok"], structured
            return structured["value"]

        rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                           "clientInfo": {"name": "appux-proof", "version": "1"}})
        session = value(tool("session", {"operation": "read"}))
        catalog_path = args.run / "trait-catalog.json"
        catalog_path.write_text(json.dumps(session["traits"], indent=2) + "\n")
        progress = next(trait for trait in session["traits"] if trait["title"] == "Progress")
        evidence["trait"] = progress
        assert not any(trait["id"] == "bee.app:tools" for trait in session["traits"])
        before = {item["name"] for item in rpc("tools/list", {})["tools"]}
        assert not before.intersection(progress["tools"])
        requested = value(tool("session", {"operation": "request_access", "idempotency_key": "progress-proof",
                               "traits": [progress["id"]], "reason": "Create and inspect one Progress task"}))
        approve(ui, "Let this agent session use Progress", requested["approval_id"])
        def access_ready():
            return value(tool("session", {"operation": "access_status", "approval_id": requested["approval_id"]}))["status"] == "granted"
        until(access_ready, "Progress consent becomes active", 120)
        after = rpc("tools/list", {})["tools"]
        names = {item["name"] for item in after}
        assert set(progress["tools"]).issubset(names)
        assert not names.intersection({"components", "install_request", "publish", "application_open"})
        evidence["exposed_tools"] = sorted(names)
        evidence["create"] = value(tool("progress_create", {"title": "Appux real MCP proof", "actor": "appux-proof"}))
        evidence["tree"] = value(tool("progress_tree", {}))
        session = value(tool("session", {"operation": "read"}))
        active = [trait for trait in session["active_traits"] if trait != progress["id"]]
        value(tool("session", {"operation": "select", "expected_revision": session["revision"],
                               "active_traits": active, "context": session["context"]}))
        deselected = {item["name"] for item in rpc("tools/list", {})["tools"]}
        assert not deselected.intersection(progress["tools"])
        session = value(tool("session", {"operation": "read"}))
        value(tool("session", {"operation": "select", "expected_revision": session["revision"],
                               "active_traits": [*active, progress["id"]], "context": session["context"]}))
        evidence["reselected_tree"] = value(tool("progress_tree", {}))
        evidence["close"] = []
        for action in ("Ctrl+W", "window X", "Escape"):
            ui.open("Progress"); ui.wait_for("PROGRESS")
            screen = ui.screen()
            started = time.monotonic()
            if action == "window X":
                lines = screen.splitlines()
                row = next(i for i, line in enumerate(lines) if "╭─ Progress" in line)
                column = lines[row].index("×", lines[row].index("╭─ Progress"))
                ui.type(f"\x1b[<0;{column+1};{row+1}M\x1b[<0;{column+1};{row+1}m")
            else:
                ui.press("C-w" if action == "Ctrl+W" else "Escape")
            until(lambda: "Progress" not in ui.screen().splitlines()[0], "Progress closes", 10)
            evidence["close"].append({"action": action, "milliseconds": round((time.monotonic()-started)*1000, 2)})
        evidence["result"] = "passed"
        args.run.mkdir(parents=True, exist_ok=True)
        (args.run / "app-traits-proof.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps({"result": "passed", "trait": progress["id"], "tools": progress["tools"], "close": evidence["close"]}))
    finally:
        if pairing and pairing.poll() is None:
            pairing.terminate(); pairing.communicate(timeout=10)
        journey.close()


if __name__ == "__main__":
    main()
