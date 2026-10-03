#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native fixture provider; stage a review through its admitted MCP gateway."""
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.request
from urllib.parse import urlsplit

MARKER = "OWNER JOURNEY STUB OUTPUT"


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def stage_review(arguments):
    position = arguments.index("--mcp-config")
    server = json.loads(arguments[position + 1])["mcpServers"]["bee"]
    endpoint = server["url"]
    if urlsplit(endpoint).hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError("fixture gateway must be loopback")
    reference = re.fullmatch(r"Bearer \$\{([A-Za-z_][A-Za-z0-9_]*)\}", server["headers"]["Authorization"])
    if reference is None:
        raise ValueError("fixture gateway requires an environment reference")
    # Consume only the attempt's gateway token as the provider does. No login
    # files, credentials stores or token values enter fixture evidence.
    authorization = "Bearer " + os.environ[reference[1]]
    sequence = 0

    def rpc(method, params):
        nonlocal sequence
        sequence += 1
        body = json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}).encode()
        request = urllib.request.Request(endpoint, data=body, headers={"Content-Type": "application/json",
            "Accept": "application/json", "Authorization": authorization})
        # Explicit transport bound for one loopback request, not an approval deadline.
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
        if "error" in result:
            raise ValueError("MCP " + json.dumps(result["error"]))
        return result["result"]

    def tool(name, values):
        result = rpc("tools/call", {"name": name, "arguments": values})
        value = json.loads(result["content"][0]["text"])
        if not value["ok"]:
            failure = value["error"] if "error" in value else {"code": value["code"], "message": value["message"]}
            raise ValueError(name + ": " + json.dumps(failure))
        return value["value"]

    rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "owner-journey-fixture", "version": "1"}})
    guide = tool("overlay", {"operation": "guide", "include_example": True})
    example = guide["example"]
    source = "counter"
    tool("overlay", {"operation": "create", "overlay_id": source,
        "expected_revision": 0, "idempotency_key": "hive-create"})
    tool("overlay", {"operation": "put", "overlay_id": source, "expected_revision": 1,
        "idempotency_key": "hive-put", "path": example["path"], "content": example["entries_json"]})
    frozen = tool("overlay", {"operation": "freeze", "overlay_id": source,
        "expected_revision": 2, "idempotency_key": "hive-freeze"})
    staged = tool("delivery", {"operation": "request", "source_overlay_id": source,
        "version": "1.0.0", "snapshot_digest": frozen["digest"]})
    if not staged["ready"]:
        raise ValueError("native review preflight: " + json.dumps(staged["diagnostics"]))
    emit({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "text", "text": "OWNER JOURNEY REVIEW STAGED"}]}})


def main(arguments):
    if arguments and arguments[0] == "--version":
        print("2.1.265")
        return
    if arguments and arguments[0] == "--help":
        print("--permission-mode --model --effort --append-system-prompt-file")
        return
    if arguments and arguments[0] == "auth":
        emit({"loggedIn": True, "authMethod": "fixture"})
        return
    emit({"type": "system", "subtype": "init", "session_id": "owner-journey-fixture"})
    if any("JOURNEY_HIVE_APPROVAL" in argument for argument in arguments):
        stage_review(arguments)
    for argument in arguments:
        if "JOURNEY_GATE=" in argument:
            gate = argument.rsplit("JOURNEY_GATE=", 1)[1]
            if "/.wippy/" not in gate:
                raise ValueError("fixture release FIFO must be under .wippy")
            with Path(gate).open() as release:
                release.readline()
    emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": MARKER}]}})
    emit({"type": "result", "subtype": "success", "is_error": False, "result": MARKER,
        "session_id": "owner-journey-fixture", "usage": {"input_tokens": 1, "output_tokens": 1}})


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, IndexError, OSError) as error:
        print("Owner journey fixture failed: " + str(error), file=sys.stderr)
        emit({"type": "result", "subtype": "error", "is_error": True, "result": str(error),
            "session_id": "owner-journey-fixture"})
        sys.exit(1)
