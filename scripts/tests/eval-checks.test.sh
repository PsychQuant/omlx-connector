#!/bin/bash
# Unit tests for scripts/eval/check.py — the mechanical checks used by `make eval`.
#
# WHY THESE ARE IN THE HERMETIC SUITE: check.py is pure text processing. No model, no
# network, no oMLX. The harness that *uses* it (scripts/eval/run.sh) needs a live
# server and is deliberately outside `make test`; the checks themselves are the only
# part with a right answer, so they stay verified on every machine and in CI.
#
# EVERY CHECK HAS BOTH DIRECTIONS. CLAUDE.md records the dual traps this repo has
# already paid for: a check that refuses everything passes every negative test, and a
# test whose fixtures come from the same mental model as the code cannot disconfirm it.
# So each check below gets a fixture it MUST fail on and one it MUST pass on. Neuter
# any single check inside check.py to `ok = True` and exactly one case must go red;
# neuter it to `ok = False` and its sibling must.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO/scripts/eval/check.py"
PASS=0
FAIL=0
SKIP=0

skip() { echo "  SKIP — $1"; SKIP=$((SKIP + 1)); }

# verdict <description> <expected: ok|not-ok> <check-name> <expect-json> <text>
#
# check.py exits 0 whenever the check RAN, and reports its verdict in the JSON. That
# separation matters: "the check said no" and "the check blew up" are different
# results, and a harness that conflates them reports a crash as a finding.
verdict() {
    local desc="$1" expect="$2" name="$3" spec="$4" text="$5"
    local out rc actual
    out=$(printf '%s' "$text" | python3 "$CHECK" --check "$name" --expect "$spec" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL — $desc (check.py exited $rc: $out)"
        FAIL=$((FAIL + 1))
        return
    fi
    case $(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null) in
        True)  actual=ok ;;
        False) actual=not-ok ;;
        *)     echo "  FAIL — $desc (unparseable verdict: $out)"; FAIL=$((FAIL + 1)); return ;;
    esac
    if [ "$actual" = "$expect" ]; then
        echo "  ok   — $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — $desc (expected $expect, got $actual)"
        echo "         $out"
        FAIL=$((FAIL + 1))
    fi
}

echo "eval/check.py"

command -v python3 >/dev/null 2>&1 || {
    skip "python3 not available — the mechanical checks cannot run"
    echo; echo "  $PASS passed, $FAIL failed, $SKIP skipped"
    [ -n "${REQUIRE_FULL_SUITE:-}" ] && { echo "  REQUIRE_FULL_SUITE set — a skip is a failure"; exit 1; }
    exit 0
}
[ -f "$CHECK" ] || { echo "  FAIL — $CHECK does not exist"; exit 1; }

# ── sentence_count ────────────────────────────────────────────────────────────────
# local_summarize's prompt says "at most N sentence(s)", so this is a ceiling, not an
# equality. Under-shooting is not a violation of what was asked.
verdict "sentence_count refuses 4 sentences when 2 were asked" not-ok sentence_count '{"max":2}' \
    'The meeting set a deadline. Two people objected. The vote carried. Notes follow.'
verdict "sentence_count accepts 2 sentences when 2 were asked" ok sentence_count '{"max":2}' \
    'The meeting set a deadline. The vote carried.'
verdict "sentence_count counts 。 as a terminator" not-ok sentence_count '{"max":2}' \
    '會議訂下了期限。兩個人反對。表決通過。紀錄如下。'
verdict "sentence_count does not split on a decimal point" ok sentence_count '{"max":1}' \
    'The threshold was set at 0.05 for this analysis.'

# ── no_preamble ───────────────────────────────────────────────────────────────────
# The server sends outputOnlyRule as its system prompt (Sources/OmlxConnectorMCP/Server.swift).
# This measures whether the model actually obeyed it.
verdict "no_preamble refuses 'Here is a summary of the text:'" not-ok no_preamble '{}' \
    'Here is a summary of the text: the deadline moved to March.'
verdict "no_preamble refuses a Chinese lead-in" not-ok no_preamble '{}' \
    '以下是這段文字的摘要：期限延到三月。'
verdict "no_preamble accepts a reply that starts with content" ok no_preamble '{}' \
    'The deadline moved to March and two people objected.'
verdict "no_preamble does not trip on content that merely contains a colon" ok no_preamble '{}' \
    'Three items were deferred: budget, venue, and the vote.'

# ── script_purity ─────────────────────────────────────────────────────────────────
# The documented failure on issue #1: a small model asked for 繁體中文 emitted mixed
# Traditional and Simplified. Simplified-only characters are the signal.
verdict "script_purity refuses 简体 mixed into a 繁體 reply" not-ok script_purity '{"script":"traditional"}' \
    '這个會議訂下了期限，两個人反對。'
verdict "script_purity accepts an all-繁體 reply" ok script_purity '{"script":"traditional"}' \
    '這個會議訂下了期限，兩個人反對。'
verdict "script_purity accepts a reply with no Han characters at all" ok script_purity '{"script":"traditional"}' \
    'The deadline moved to March.'

# ── category_member ───────────────────────────────────────────────────────────────
verdict "category_member refuses a label outside the candidate list" not-ok category_member \
    '{"categories":["bug","feature","question"]}' 'enhancement'
verdict "category_member accepts a label in the candidate list" ok category_member \
    '{"categories":["bug","feature","question"]}' 'feature'
verdict "category_member tolerates surrounding whitespace and case" ok category_member \
    '{"categories":["bug","feature","question"]}' '  Feature
'
verdict "category_member refuses a label that merely contains a candidate" not-ok category_member \
    '{"categories":["bug","feature"]}' 'This is a feature request, I think.'

# ── unknown check ─────────────────────────────────────────────────────────────────
# A typo in a case file must be an error, not a silent pass. This is the eval-harness
# failure mode CLAUDE.md warns about — plausible rows, nothing actually asserted.
if printf 'x' | python3 "$CHECK" --check no_such_check --expect '{}' >/dev/null 2>&1; then
    echo "  FAIL — an unknown check name exited 0 (a typo in a case file would pass silently)"
    FAIL=$((FAIL + 1))
else
    echo "  ok   — an unknown check name is an error, not a silent pass"
    PASS=$((PASS + 1))
fi

# ── --spec mode: what run.sh actually calls ───────────────────────────────────────
SPEC_OUT=$(printf 'Here is a summary: one. Two. Three.' | python3 "$CHECK" --spec \
    '{"sentence_count":{"max":2},"no_preamble":{}}' 2>&1)
if [ $? -ne 0 ]; then
    echo "  FAIL — --spec mode exited nonzero: $SPEC_OUT"
    FAIL=$((FAIL + 1))
else
    n=$(printf '%s' "$SPEC_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["checks"]), d["all_ok"])' 2>/dev/null)
    if [ "$n" = "2 False" ]; then
        echo "  ok   — --spec mode runs every named check and reports all_ok"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — --spec mode returned '$n', expected '2 False'"
        FAIL=$((FAIL + 1))
    fi
fi

# ── rpc.py score: the envelope handling, also hermetic ────────────────────────────
# check.py's verdicts are mutation-proven above, but nothing yet showed that a FAILING
# verdict actually reaches a row. The end-to-end run that motivated these cases came
# back all-green, so the path from "a check said no" to "the row says so" was carried
# entirely by inspection. That is the shape of defect this repo keeps producing: the
# mechanism harmless, the reporting untested. rpc.py score takes a response on stdin
# and needs no model, so it belongs here rather than in the hand-checked half.
RPC="$REPO/scripts/eval/rpc.py"
CASES="$REPO/scripts/eval/cases/summarize.json"

# row <description> <expected all_ok: true|false|null> <response-json>
row() {
    local desc="$1" want="$2" resp="$3" out rc got
    out=$(printf '%s' "$resp" | python3 "$RPC" score --case-file "$CASES" --index 0 \
              --model-requested "" --check "$CHECK" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL — $desc (rpc.py score exited $rc: $out)"; FAIL=$((FAIL + 1)); return
    fi
    got=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["all_ok"]))' 2>/dev/null)
    if [ "$got" = "$want" ]; then
        echo "  ok   — $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL — $desc (all_ok was $got, expected $want)"; echo "         $out"; FAIL=$((FAIL + 1))
    fi
}

# A reply that breaks the sentence ceiling AND opens with a preamble must reach the row
# as all_ok=false. Case 0 asks for at most 2 sentences.
row "a violating reply produces all_ok=false" false \
    '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"task\":\"summarize\",\"model\":\"m\",\"elapsed_seconds\":1.0,\"text\":\"Here is a summary of the text: one. Two. Three. Four.\"}"}]}}'
row "a compliant reply produces all_ok=true" true \
    '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"task\":\"summarize\",\"model\":\"m\",\"elapsed_seconds\":1.0,\"text\":\"The deadline moved to 5 April. Funding was approved at 60%.\"}"}]}}'
# A tool error is a RESULT to record, not a harness crash: all_ok stays null and the
# reason is preserved. Scoring it as a pass, or aborting the run, both lose information.
row "a tool error is recorded, not scored" null \
    '{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"Error: could not reach the local server"}]}}'
row "a JSON-RPC error is recorded, not scored" null \
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}'

# human_review is the half issue #1 asks NOT to be auto-judged. If it does not reach the
# row, that half is silently absent from every result anyone reads.
HR=$(printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"text\":\"x.\",\"model\":\"m\"}"}]}}' \
     | python3 "$RPC" score --case-file "$CASES" --index 0 --model-requested "" --check "$CHECK" \
     | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["human_review"]))' 2>/dev/null)
if [ "${HR:-0}" -gt 0 ]; then
    echo "  ok   — human_review reaches the row (the non-auto-judged half stays visible)"
    PASS=$((PASS + 1))
else
    echo "  FAIL — human_review missing from the row"
    FAIL=$((FAIL + 1))
fi

# Every case file must name only checks that exist. A typo would otherwise surface as a
# mid-run abort against a live model, minutes in.
for cf in "$REPO"/scripts/eval/cases/*.json; do
    bad=$(python3 -c '
import json, sys
sys.path.insert(0, sys.argv[2])
import importlib.util
spec = importlib.util.spec_from_file_location("chk", sys.argv[3])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
doc = json.load(open(sys.argv[1]))
missing = sorted({n for c in doc["cases"] for n in c.get("expect", {}) if n not in m.CHECKS})
print(",".join(missing))' "$cf" "$REPO/scripts/eval" "$CHECK" 2>&1)
    if [ -z "$bad" ]; then
        echo "  ok   — $(basename "$cf") names only checks that exist"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — $(basename "$cf") names unknown check(s): $bad"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$SKIP" -gt 0 ] && [ -n "${REQUIRE_FULL_SUITE:-}" ]; then
    echo "  REQUIRE_FULL_SUITE set — a skip is a failure"
    exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
