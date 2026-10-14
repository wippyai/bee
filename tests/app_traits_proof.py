"""Real Bee MCP proof using the Hub app and the existing bee-e2e UI driver."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bee", type=Path, required=True)
    parser.add_argument("--e2e", type=Path, required=True)
    parser.add_argument("--run", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.e2e.resolve()))
    from bee_e2e.journey import Journey
    from bee_e2e.wait import until
    from journeys.progress import install_progress_app, approve_progress

    journey = Journey(args.e2e.resolve(), args.run.resolve(), "app-traits", args.bee.resolve(), 120)
    pairing = None
    evidence = {"binary_sha256": hashlib.sha256(args.bee.read_bytes()).hexdigest()}
    try:
        ui = journey.add()
        install_progress_app(ui)
        evidence["hub_install"] = "bee/progress"
        pairing = subprocess.Popen([str(args.bee.resolve()), "mcp", "connect", "--name", "Appux proof"],
                                   cwd=ui.node.root, env=ui.node.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        until(lambda: any(row["state"] == "pending" and "Appux proof" in row["prompt_json"]
                          for row in ui.node.state("approvals")["rows"]),
              "MCP pairing approval arrives", 120, ui.screen)
        approve_progress(ui, "Appux proof")
        output, error = pairing.communicate(timeout=120)
        assert pairing.returncode == 0, "pairing failed: " + error
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
        progress = next(trait for trait in session["traits"] if trait["title"] == "Progress")
        evidence["trait"] = progress
        assert not any(trait["id"] == "bee.app:tools" for trait in session["traits"])
        before = {item["name"] for item in rpc("tools/list", {})["tools"]}
        assert not before.intersection(progress["tools"])
        requested = value(tool("session", {"operation": "request_access", "idempotency_key": "progress-proof",
                               "traits": [progress["id"]], "reason": "Create and inspect one Progress task"}))
        approve_progress(ui, "Progress")
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
            ui.open("Apps > Progress"); ui.wait_for("PROGRESS")
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
