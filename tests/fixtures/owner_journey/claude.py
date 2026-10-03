#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Deterministic Claude protocol fixture. Never reads provider homes or logins."""
import json
import sys
import re
from pathlib import Path

if "--version" in sys.argv:
    print("2.1.265")
elif "--help" in sys.argv:
    print("--permission-mode --model --effort --append-system-prompt-file")
elif sys.argv[1:3] == ["auth", "status"]:
    print('{"loggedIn":true,"authMethod":"fixture"}')
else:
    print(json.dumps({"type": "system", "subtype": "init", "session_id": "owner-journey-fixture"}), flush=True)
    gate = re.search(r"JOURNEY_GATE=(\S+)", " ".join(sys.argv))
    if gate:
        path = Path(gate.group(1))
        if ".wippy" not in path.parts:
            raise SystemExit("fixture gate is outside .wippy")
        with path.open() as release:
            release.readline()
    print(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "OWNER JOURNEY STUB OUTPUT"}]}}), flush=True)
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "OWNER JOURNEY STUB OUTPUT", "session_id": "owner-journey-fixture", "usage": {"input_tokens": 1, "output_tokens": 1}}), flush=True)
