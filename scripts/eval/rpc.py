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


# Runs on EVERY case, whatever `expect` says. Without it, a case with an empty or missing
# `expect` produced `checks: []` and a green row — the harness reporting without checking,
# in its own code. It also catches the plainest delegation failure there is: an empty reply
# used to satisfy every other check trivially.
ALWAYS = {"non_empty": {}}


def run_checks(check_path, text, spec):
    spec = dict(ALWAYS, **(spec or {}))
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
    return out["checks"], out["mechanical_ok"]


# `render()` (summarize / rewrite / complete) emits `text`; `handleClassify` emits
# `task/category/matched/raw_response` and no `text` at all. `payload.get("text", "")` fed
# category_member the empty string, which is never in the candidate list — so it would
# have refused EVERY classify reply. That is "a check that refuses everything", the trap
# CLAUDE.md already records, reproduced in the one check with no positive case.
#
# raw_response, not category, is what gets checked: `category` has already been matched
# back onto the caller's list by the server, so checking it against that same list is a
# tautology. raw_response is the model's actual reply, which is what "did it answer with a
# bare label as instructed" asks about.
def checkable_text(payload):
    if payload.get("task") == "classify" or "raw_response" in payload:
        return payload.get("raw_response") or "", "raw_response"
    # `.get(key, "")` defaults only on a MISSING key; an explicit JSON null returns None,
    # and None reaching subprocess.run(input=None) means "do not redirect stdin", so
    # check.py inherited this process's already-consumed stdin and checked "" instead.
    return payload.get("text") or "", "text"


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
        "mechanical_ok": None,
        "text_field": None,
        # Present only for local_classify. `matched` is the issue's actual question about
        # that tool — a wrong-but-matched answer and an unmatched one are different
        # failures — and the row dropped both.
        "category": None,
        "matched": None,
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
        row["text"], row["text_field"] = checkable_text(payload)
        row["category"] = payload.get("category")
        row["matched"] = payload.get("matched")
        row["checks"], row["mechanical_ok"] = run_checks(
            args.check, row["text"], case.get("expect", {}))

    print(json.dumps(row, ensure_ascii=False))
    return 0


def cmd_summarize(args):
    """The run's verdict, as a pure function of the output file.

    This used to be inline bash in run.sh counting rows APPENDED, under a comment saying
    "a green eval that ran no cases is the reporting-without-checking failure in its
    purest form". A recorded tool error is a row, so a run in which every single call
    failed printed "5 row(s) written, 0 error(s)" and exited 0 — the guard failing open
    on exactly the state it existed to catch. It was reproduced against the real binary.

    Counting the right thing is half the fix; the other half is being able to test it at
    all, which inline bash was not.
    """
    measured = errored = malformed = 0
    flagged = []
    review = []
    try:
        lines = open(args.out, encoding="utf-8").read().splitlines()
    except OSError as e:
        print(f"  cannot read {args.out}: {e}", file=sys.stderr)
        return 1
    for line in lines:
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            malformed += 1
            continue
        if row.get("error"):
            errored += 1
            continue
        measured += 1
        bad = [c["check"] for c in row.get("checks", []) if not c.get("ok")]
        if bad:
            flagged.append((row.get("case"), row.get("model"), bad))
        for q in row.get("human_review", []):
            review.append((row.get("case"), q))

    print(f"  measured={measured}  errored={errored}  malformed={malformed}")
    if flagged:
        print(f"  {len(flagged)} row(s) failed a mechanical check:")
        for case, model, bad in flagged:
            print(f"    {case}  [{model}]  {', '.join(bad)}")

    # The half issue #1 asks NOT to be auto-judged. run.sh never printed these — the
    # questions were written into the file and then never put in front of anyone, so
    # "recorded for human review" was one-directional. Printing them is the minimum.
    if review:
        print()
        print("  NOT CHECKED BY ANYTHING — read the `text` field and answer these yourself:")
        seen = set()
        for case, q in review:
            if (case, q) in seen:
                continue
            seen.add((case, q))
            print(f"    {case}: {q}")

    print()
    if measured == 0:
        print("  NOTHING WAS MEASURED. Every call errored or the file is empty —", file=sys.stderr)
        print("  this is not a passing run, it is a run that did not happen.", file=sys.stderr)
        return 1
    print("  A green mechanical row is NOT a statement that the model was good: coverage")
    print("  and faithfulness are deliberately unscored. See scripts/eval/README.md.")
    return 1 if errored or malformed else 0


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

    z = sub.add_parser("summarize")
    z.add_argument("--out", required=True)
    z.set_defaults(func=cmd_summarize)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
