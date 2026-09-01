#!/usr/bin/env python3
"""A fake OmlxConnectorMCP for testing run.sh's failure handling, hermetically.

No oMLX, no network, no model. `--ping` succeeds so run.sh's preflight passes; then the
JSON-RPC loop answers `initialize` and however many `tools/call` requests
STUB_ANSWER_CALLS says, after which it goes silent (STUB_MODE=silent) or exits
(STUB_MODE=die). Both reproduce a transport failure, which is the case round 2 found
`make eval` reporting success for.
"""
import json, os, sys, time

if "--ping" in sys.argv:
    print("stub-mcp: reachable")
    sys.exit(0)

answer = int(os.environ.get("STUB_ANSWER_CALLS", "1"))
mode = os.environ.get("STUB_MODE", "silent")
calls = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("method") == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                          "result": {"protocolVersion": "2024-11-05", "capabilities": {},
                                     "serverInfo": {"name": "stub", "version": "0"}}}), flush=True)
    elif msg.get("method") == "tools/call":
        calls += 1
        if calls > answer:
            if mode == "die":
                os._exit(3)
            time.sleep(3600)      # answer nothing, ever
        payload = json.dumps({"task": "summarize", "model": "stub-model",
                              "elapsed_seconds": 0.1, "text": "One. Two."})
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                          "result": {"content": [{"type": "text", "text": payload}]}}), flush=True)
