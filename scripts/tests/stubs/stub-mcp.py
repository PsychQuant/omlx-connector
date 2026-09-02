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

# `nohandshake` must fail only the FIRST invocation, or a two-model run loses both models
# and the "nothing measured" gate fires for the wrong reason — the test would pass while
# discriminating nothing. run.sh starts one process per model, so a marker file in the
# scratch dir is what distinguishes them.
if mode == "nohandshake":
    marker = os.environ.get("STUB_MARKER", "")
    if marker and not os.path.exists(marker):
        open(marker, "w").close()   # first invocation: refuse to handshake
    else:
        mode = "silent"
calls = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("method") == "initialize" and mode == "nohandshake":
        # A model whose session never starts. Round 3: run.sh dropped it with a stderr
        # line and zero rows, and the verdict — which reasons only about rows that exist —
        # published a half-missing cross-size comparison at exit 0.
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
        if mode == "toolerror":
            # A TOOL error, not a transport one: the server answers, and the answer is a
            # refusal. Round 1 was entirely about this branch; until this mode existed no
            # test could reach it, which is how a NameError shipped on it in round 4. The
            # message carries a CSI sequence on purpose — the sanitiser on this path is
            # what the test is checking.
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                              "result": {"isError": True,
                                         "content": [{"type": "text",
                                                      "text": "Error: stub refused \x1b[2K the request"}]}}),
                  flush=True)
            continue
        payload = json.dumps({"task": "summarize",
                              # STUB_MODEL lets a test plant escapes/newlines in the served
                              # id, which is server-authored and reaches the terminal.
                              "model": os.environ.get("STUB_MODEL", "stub-model"),
                              "elapsed_seconds": 0.1, "text": "One. Two."})
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                          "result": {"content": [{"type": "text", "text": payload}]}}), flush=True)
