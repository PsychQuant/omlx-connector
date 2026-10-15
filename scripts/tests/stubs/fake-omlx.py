#!/usr/bin/env python3
"""A fake oMLX HTTP server, so the REAL binary's client code can be tested hermetically.

Binds 127.0.0.1 on an ephemeral port and prints it on stdout. Serves the two endpoints
OmlxClient uses. `/v1/chat/completions` deliberately reports a DIFFERENT `model` than the
request asks for — that is the whole point: it is the only way to tell whether the row
records what the server served or merely echoes what was requested.

Loopback only, no egress; LoopbackPolicy accepts 127.0.0.1, so the binary's own preflight
and address check run for real rather than being bypassed.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SERVED = "served-id-not-requested"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # keep the suite's output clean
        pass

    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # The real endpoint is /v1/models/status returning {"models": [...]}, not the
        # OpenAI-shaped /v1/models. Getting this wrong made the binary's own preflight fail
        # with "returned no content" — which is the fixture being wrong, not the code, and
        # is exactly why a fixture that constructs something must assert it works.
        if self.path.startswith("/v1/models"):
            self._send({"models": [
                {"id": SERVED, "loaded": True, "max_context_window": 4096, "model_type": "lm"},
                {"id": "some-other-model", "loaded": False},
            ]})
        else:
            self.send_error(404)

    def do_POST(self):
        if not self.path.startswith("/v1/chat/completions"):
            return self.send_error(404)
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send({
            "model": SERVED,                      # NOT what the caller asked for
            "choices": [{"message": {"content": "One sentence."}, "finish_reason": "stop"}],
            "usage": {"completion_tokens": 3, "total_time": 0.01},
        })


srv = HTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1], flush=True)
srv.serve_forever()
