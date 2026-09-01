#!/usr/bin/env python3
"""Request construction and row scoring for scripts/eval/run.sh.

Deliberately separate from check.py. check.py is pure text-in/verdict-out with no I/O,
which is what lets the hermetic suite verify it on a machine with no oMLX; this file
reads case files, parses MCP envelopes and shells out. Merging the two would drag file
and subprocess handling into the one part of the harness that has a right answer.

Two subcommands, both used by run.sh and nothing else:

    rpc.py request --case-file F --index I --id N --model M   → a JSON-RPC line
    rpc.py score   --case-file F --index I --model-requested M --check P  < response
                                                              → one JSONL row
"""

import argparse
import json
import subprocess
import sys


def load_case(path, index):
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    return doc["cases"][index]


def cmd_request(args):
    case = load_case(args.case_file, args.index)
    arguments = dict(case["arguments"])
    # A model override is the caller's, not the case's: the same case has to be
    # runnable against every model, since comparing across sizes is the whole point.
    if args.model:
        arguments["model"] = args.model
    print(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": args.id,
                "method": "tools/call",
                "params": {"name": case["tool"], "arguments": arguments},
            },
            ensure_ascii=False,
        )
    )
    return 0


def extract_reply(response):
    """Pull the tool's payload out of the MCP envelope.

    Returns (payload_dict, error_string). Exactly one is non-None. A tool error is a
    RESULT, not a harness failure — a model that refuses or a server that is down is
    something the row should record, not something that should abort the run.
    """
    if "error" in response:
        err = response["error"]
        return None, "JSON-RPC error: %s" % err.get("message", json.dumps(err))
    result = response.get("result") or {}
    content = result.get("content") or []
    text = ""
    for block in content:
        if block.get("type") == "text" or "text" in block:
            text = block.get("text", "")
            break
    if result.get("isError"):
        return None, text or "tool reported isError with no message"
    if not text:
        return None, "empty response content"
    try:
        return json.loads(text), None
    except json.JSONDecodeError:
        # Handlers return formatJSON output, so this means the contract changed.
        # Recording the raw text beats discarding it.
        return None, "reply was not JSON: %s" % text[:200]


def run_checks(check_path, text, spec):
    if not spec:
        return [], True
    proc = subprocess.run(
        [sys.executable, check_path, "--spec", json.dumps(spec, ensure_ascii=False)],
        input=text,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        # A malformed expectation is a bug in the case file. Fail loudly: a check that
        # silently does not run is an eval that reports without checking.
        raise SystemExit("check.py failed (%d): %s" % (proc.returncode, proc.stderr.strip()))
    out = json.loads(proc.stdout)
    return out["checks"], out["all_ok"]


def cmd_score(args):
    case = load_case(args.case_file, args.index)
    response = json.load(sys.stdin)
    payload, error = extract_reply(response)

    row = {
        "case": case["id"],
        "why": case.get("why", ""),
        "tool": case["tool"],
        "model_requested": args.model_requested or None,
        "model": None,
        "elapsed_seconds": None,
        "finish_reason": None,
        "text": None,
        "checks": [],
        "all_ok": None,
        # Carried into the row on purpose: the half of issue #1 that is deliberately not
        # auto-judged has to be visible to whoever reads the results, or it evaporates.
        "human_review": case.get("human_review", []),
        "error": error,
    }
    if payload is not None:
        row["model"] = payload.get("model")
        row["elapsed_seconds"] = payload.get("elapsed_seconds")
        # Present only when the model did NOT stop on its own — a reply cut off at the
        # token limit is a different finding from a reply that ignored the instruction,
        # and a row that conflates them invites the wrong conclusion.
        row["finish_reason"] = payload.get("finish_reason")
        row["text"] = payload.get("text", "")
        row["checks"], row["all_ok"] = run_checks(args.check, row["text"], case.get("expect", {}))

    print(json.dumps(row, ensure_ascii=False))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("request")
    r.add_argument("--case-file", required=True)
    r.add_argument("--index", type=int, required=True)
    r.add_argument("--id", type=int, required=True)
    r.add_argument("--model", default="")
    r.set_defaults(func=cmd_request)

    s = sub.add_parser("score")
    s.add_argument("--case-file", required=True)
    s.add_argument("--index", type=int, required=True)
    s.add_argument("--model-requested", default="")
    s.add_argument("--check", required=True)
    s.set_defaults(func=cmd_score)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
