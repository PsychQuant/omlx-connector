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
import os
import re
import subprocess
import sys

EX_USAGE = 64   # the contract's fourth code: a bad flag or a malformed value, in EVERY program


class Parser(argparse.ArgumentParser):
    """argparse exits 2 on a usage error, which the settled exit-code contract defines as
    "the run happened and there are findings". Round 3 found that collision in run.sh;
    round 4 fixed run.sh and left check.py and this file at 2. 64 (EX_USAGE) everywhere."""

    def error(self, message):
        self.print_usage(sys.stderr)
        print(f"{self.prog}: error: {message}", file=sys.stderr)
        sys.exit(EX_USAGE)


# Fields a case may assert on with `expect_row`. These are the keys the tool payloads
# actually carry (see Server.swift's render() and handleClassify).
ROW_FIELDS = {"task", "category", "matched", "model", "finish_reason", "elapsed_seconds"}


# Model- and server-authored strings reach the operator's terminal. Round 3 demonstrated a
# stub returning a `model` id containing CSI and OSC sequences that erased the line, forged
# a harness verdict and changed the window title. This repo already has the convention —
# CLAUDE.md: "system-generated strings are not trusted into logs" — it just had not been
# applied to this path.
#
# ALL of C0 and C1, tab and newline included. Round 3's version left \x09 and \x0a in the gap
# between its two ranges, so a server id carrying "\n" still split the flagged-rows table into
# a forged second line — line forging being the simplest way to forge a verdict. And it was
# applied to `model` only; `finish_reason`, `error`, case ids and the review prompts all reached
# the terminal raw.
_UNSAFE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def safe(value, limit=None):
    """Strip control characters from anything we did not author before printing it.

    `limit` is opt-in. Operator-authored text (case ids, human_review) is stripped of controls
    and otherwise printed whole — round 4 truncated the one declared limit that reaches the
    operator at 300 characters, mid-sentence, dropping its actionable clause.
    """
    if value is None:
        return None
    out = _UNSAFE.sub("\ufffd", str(value))
    return out if limit is None else out[:limit]


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

        # expect_row: assertions about the ROW, not the reply text. `matched` is a payload
        # field, so no text check can express "matched must be false" — and for
        # out-of-domain content that is exactly the question issue #1 asks. Scoring it with
        # category_member pointed the verdict BACKWARDS: the desired outcome (no label
        # named) failed, the undesired one (forcing a label) passed.
        for field, want in (case.get("expect_row") or {}).items():
            # A typo here used to be indistinguishable from a model finding, and WORSE than
            # a loud failure: `{"matchd": false}` compares None != False, so it FLAGs on
            # every model forever and the run exits 2 — "a model did badly, which is data".
            # `expect` has a name guard; this channel was added without one.
            if field not in ROW_FIELDS:
                raise SystemExit(
                    f"unknown expect_row field {field!r} in case {case['id']!r} "
                    f"(known: {', '.join(sorted(ROW_FIELDS))})")
            got = payload.get(field)
            row["checks"].append({
                "check": f"row.{field}",
                "ok": got == want,
                "observed": got,
                "expected": want,
                "detail": f"{field}={got!r}" + ("" if got == want else f", expected {want!r}"),
            })
        row["mechanical_ok"] = all(c["ok"] for c in row["checks"])

    print(json.dumps(row, ensure_ascii=False))
    return 0


def completeness(measured, errored, malformed, owed, pairs=None, expected_pairs=None):
    """THE ONE DEFINITION OF A COMPLETE RUN. Returns None if complete, else the reason.

    Round 4 had two: run.sh's publish gate said "measured >= 1 and no errors", summarize said
    "and total == owed", and `mv` ran before the stricter one — so README's "only ever holds a
    complete run" was overstated. Both callers now ask this function.

    The count is an EQUALITY. Round 4 checked `total < owed` only, so a duplicated model or
    case file produced more rows than owed at exit 0, the accounting consistent with itself.
    """
    total = measured + errored + malformed
    if measured == 0:
        return "NOTHING WAS MEASURED — every call errored or the file is empty."
    if errored or malformed:
        return f"{errored} call(s) failed and {malformed} row(s) were unreadable."
    if owed and total < owed:
        return f"{owed - total} row(s) were never written — {total} of {owed} owed."
    if owed and total > owed:
        return f"{total - owed} MORE row(s) than the run owed ({total} of {owed}) — a model or case file ran twice."
    # IDENTITY, not cardinality. Round 5 compared counts only, so five rows for one case and
    # none for four others was "complete", and a byte-identical copy of a case file doubled
    # the run with self-consistent books. The run writes the (model, case) pairs it owes and
    # the multiset of rows must equal it — no missing, no extra, no duplicates.
    if expected_pairs is not None:
        have = sorted((m or "", c or "") for m, c in (pairs or []))
        want = sorted((m or "", c or "") for m, c in expected_pairs)
        if have != want:
            missing = [f"{m}/{c}" for m, c in want if (m, c) not in have][:3]
            extra = [f"{m}/{c}" for m, c in have if (m, c) not in want][:3]
            dup = len(have) - len(set(have))
            return ("rows do not match the (model, case) pairs owed — "
                    + (f"missing {missing} " if missing else "")
                    + (f"unexpected {extra} " if extra else "")
                    + (f"{dup} duplicate(s)" if dup else "")).strip()
    return None


def read_rows(path):
    """(measured, errored, malformed, pairs) over a JSONL file; pairs are (model_requested,
    case) for every parseable row, error rows included — the run owes a row per pair
    whatever its outcome. A missing file counts as nothing measured."""
    measured = errored = malformed = 0
    pairs = []
    try:
        for line in open(path, encoding="utf-8"):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            pairs.append((row.get("model_requested") or "", row.get("case") or ""))
            if row.get("error"):
                errored += 1
            else:
                measured += 1
    except OSError:
        pass
    return measured, errored, malformed, pairs


def load_expected_pairs(path):
    if not path:
        return None
    with open(path, encoding="utf-8") as fh:
        return [(m or "", c or "") for m, c in json.load(fh)]


def cmd_complete(args):
    """Exit 0 iff the staging file is a complete run. run.sh's publish decision."""
    measured, errored, malformed, pairs = read_rows(args.out)
    expected_pairs = load_expected_pairs(args.expect_rows)
    owed = args.expected or (len(expected_pairs) if expected_pairs is not None else 0)
    verdict = completeness(measured, errored, malformed, owed, pairs, expected_pairs)
    if verdict:
        print(verdict)
        return 1
    return 0


def cmd_append(args):
    """Append stdin to --out without following symlinks.

    Round 3 planted a symlink at `<out>.partial` and watched `: >` truncate its target; round
    4 added check-then-write refusals, and round 4's verify named the class: anything created
    between the check and the write wins. O_NOFOLLOW makes the write itself the defence — a
    symlink that appears in the window fails the open instead of being followed.
    """
    # No O_TRUNC in the open: truncation happens only after the descriptor has been
    # inspected. O_NOFOLLOW is symlink-specific — a HARD LINK to a regular file is a regular
    # file, passes `[ -L ]` and `[ -f ]`, and round 5's `--create` truncated the linked
    # victim through every guard. fstat on the open descriptor sees the link count, and that
    # check has no window: the descriptor IS the file.
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(args.out, flags, 0o644)
    except OSError as e:
        print(f"refusing to write {args.out}: {e.strerror}", file=sys.stderr)
        return 1
    st = os.fstat(fd)
    if st.st_nlink > 1:
        os.close(fd)
        print(f"refusing to write {args.out}: it has {st.st_nlink} hard links", file=sys.stderr)
        return 1
    if args.create:
        os.ftruncate(fd, 0)
    data = sys.stdin.buffer.read()
    with os.fdopen(fd, "ab") as fh:
        fh.write(data)
    return 0


def cmd_rowline(args):
    """The per-case status line run.sh prints. Moved out of an inline `python3 -c` because that
    is where round 4 shipped `re.sub` one line above `import re`, on the tool-error branch —
    which no test could reach — so every recorded tool error printed a traceback."""
    d = json.load(sys.stdin)
    if d.get("error"):
        print("tool error — " + safe(d["error"], 60))
        return 0
    bad = [c["check"] for c in d.get("checks", []) if not c.get("ok")]
    mark = "ok  " if not bad else "FLAG"
    extra = "" if not bad else "  " + safe(",".join(bad), 120)
    fin = "" if not d.get("finish_reason") else "  [%s]" % safe(d["finish_reason"], 40)
    print("%s  %5.1fs  %s%s%s" % (mark, d.get("elapsed_seconds") or 0.0,
                                  safe(d.get("model") or "?", 80), fin, extra))
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
    pairs = []
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
        pairs.append((row.get("model_requested") or "", row.get("case") or ""))
        if row.get("error"):
            errored += 1
            continue
        measured += 1
        bad = [c["check"] for c in row.get("checks", []) if not c.get("ok")]
        if bad:
            flagged.append((row.get("case"), row.get("model"), bad))
        for q in row.get("human_review", []):
            review.append((row.get("case"), q))

    total = measured + errored + malformed
    expected_pairs = load_expected_pairs(args.expect_rows)
    owed = args.expected or (len(expected_pairs) if expected_pairs is not None else 0)
    print(f"  measured={measured}  errored={errored}  malformed={malformed}"
          + (f"  (of {owed} owed)" if owed else ""))
    verdict = completeness(measured, errored, malformed, owed, pairs, expected_pairs)
    if flagged:
        print(f"  {len(flagged)} row(s) failed a mechanical check:")
        for case, model, bad in flagged:
            print(f"    {safe(case, 60)}  [{safe(model, 80)}]  {safe(', '.join(bad), 120)}")

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
            print(f"    {safe(case, 60)}: {safe(q)}")

    print()
    # THE EXIT-CODE CONTRACT. Round 2 found the previous two-way split indefensible: a tool
    # error exited 1 while a model returning an empty string exited 0, so the axis was
    # "which layer did the emptiness happen at" rather than "what does it mean". Worse, the
    # only machine-read verdict called an all-red run a success, and the test suite had
    # pinned that as intended.
    #
    #   1  the run did not happen — nothing measured, or a tool/transport/malformed failure
    #   2  the run happened and there are findings — a model did badly, which is DATA
    #   0  the run happened and every mechanical check passed
    #
    # 2 rather than 1 for findings because `make eval` must not fail merely because a model
    # is imperfect, which it always is; and not 0, because automation reading this is the
    # only consumer that cannot read the prose above.
    # The shortfall check. Every fail-open variant three verify rounds found reduces to
    # this one number being unknown: rows that were never written cannot be reasoned about
    # from the rows that were. Comparing against what the run OWED catches them all,
    # including whichever branch would have been added next.
    if verdict:
        print(f"  {verdict}", file=sys.stderr)
        print("  This run is not a result.", file=sys.stderr)
        return 1
    if flagged:
        print(f"  {len(flagged)} row(s) have findings. The run itself was fine — this is a")
        print("  measurement, not a build failure. Read them above.")
        return 2
    print("  Every mechanical check passed. That is NOT a statement that the model was")
    print("  good: coverage and faithfulness are deliberately unscored, and the questions")
    print("  above are unanswered until a person answers them. See scripts/eval/README.md.")
    return 0


def main(argv=None):
    p = Parser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)

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
    z.add_argument("--expected", type=int, default=0,
                   help="how many rows the run owed (models x cases); 0 disables the check")
    z.add_argument("--expect-rows", default="",
                   help="JSON file: the [model, case] pairs the run owes; rows must match exactly")
    z.set_defaults(func=cmd_summarize)

    c = sub.add_parser("complete")
    c.add_argument("--out", required=True)
    c.add_argument("--expected", type=int, default=0)
    c.add_argument("--expect-rows", default="")
    c.set_defaults(func=cmd_complete)

    a = sub.add_parser("append")
    a.add_argument("--out", required=True)
    a.add_argument("--create", action="store_true", help="truncate/create instead of append")
    a.set_defaults(func=cmd_append)

    l = sub.add_parser("rowline")
    l.set_defaults(func=cmd_rowline)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
