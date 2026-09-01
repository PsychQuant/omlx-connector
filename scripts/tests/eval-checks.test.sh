#!/bin/bash
# Unit tests for scripts/eval/check.py — the mechanical checks used by `make eval`.
#
# WHY THESE ARE IN THE HERMETIC SUITE: check.py is pure text processing. No model, no
# network, no oMLX. The harness that *uses* it (scripts/eval/run.sh) needs a live
# server and is deliberately outside `make test`; the checks themselves are the only
# part with a right answer, so they stay verified on every machine and in CI.
#
# EVERY CHECK HAS BOTH DIRECTIONS, AND THE FIXTURES SIT ON THE BOUNDARY.
#
# The first version of this file claimed to be "mutation-proven in both directions".
# That was false, and the Devil's Advocate proved it: the claim held only for the
# coarsest possible mutation — replacing an entire `ok` expression with a constant.
# Real logic mutations all stayed green, because the fixtures came from the same mental
# model as the code and so could not disconfirm it. Measured on the shipped tree:
#
#   observed <= ceiling  ->  <= ceiling + 1        23 passed, 0 failed
#   all(...)             ->  any(...)              23 passed, 0 failed
#   _SIMPLIFIED_ONLY(422) ->  set("个两")           23 passed, 0 failed
#   .match               ->  .search               23 passed, 0 failed
#   11 of 13 preamble patterns, deleted one by one 23 passed, 0 failed
#
# The root cause is the one CLAUDE.md has now paid for four times: both sentence_count
# negative fixtures were `observed=4, ceiling=2` — TWO away from the boundary — so the
# comparison could be off by one undetected. Same shape as the recorded hasPrefix("127.")
# round, where every near-miss fixture broke on the character right after `127`.
#
# So the rule for adding anything here: put the fixture ON the boundary (3-vs-2, not
# 4-vs-2), and run it against the UNFIXED code first to watch it fail. Cases below marked
# `# RED-first:` were each confirmed failing before the corresponding fix was written.
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
    n=$(printf '%s' "$SPEC_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["checks"]), d["mechanical_ok"])' 2>/dev/null)
    if [ "$n" = "2 False" ]; then
        echo "  ok   — --spec mode runs every named check and reports mechanical_ok"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — --spec mode returned '$n', expected '2 False'"
        FAIL=$((FAIL + 1))
    fi
fi

# ══ BOUNDARY + MUTATION-KILLING CASES (added after the round-1 verify FAIL) ══════
#
# Each of these was run against the unfixed check.py first and observed to fail. The
# mutation it kills is named, because a case whose purpose is not written down gets
# "simplified" away by the next maintainer.

# --- sentence_count: ON the boundary. Kills `<= ceiling` -> `<= ceiling + 1`. ------
verdict "sentence_count refuses 3 sentences when 2 were asked (boundary)" not-ok sentence_count '{"max":2}' \
    'The deadline moved. Two people objected. The vote carried.'
verdict "sentence_count refuses 2 when 1 was asked (boundary)" not-ok sentence_count '{"max":1}' \
    'The deadline moved. The vote carried.'

# RED-first: the tail heuristic counted ANY non-blank remainder after the last
# terminator, so a closing delimiter belonging to the same sentence added a phantom one.
verdict "a closing quote after the final stop is not a new sentence" ok sentence_count '{"max":1}' \
    'He said "Go."'
verdict "a closing paren after the final stop is not a new sentence" ok sentence_count '{"max":1}' \
    'The deadline moved to 5 April.)'
verdict "markdown bold around the final stop is not a new sentence" ok sentence_count '{"max":1}' \
    '**The deadline moved to 5 April.**'
verdict "a CJK closing bracket after 。 is not a new sentence" ok sentence_count '{"max":1}' \
    '期限延到四月五日。」'
# ...but a real trailing clause with no terminator still counts. Without this the fix
# could simply delete the tail rule, which small models make load-bearing.
verdict "a real unterminated trailing clause still counts" not-ok sentence_count '{"max":1}' \
    'The deadline moved to 5 April. Funding was approved'

# Kills deletion of the terminator run-collapse loop. No previous fixture contained a
# run, so `?!` and `...` could each have been counted per-character undetected.
verdict "a ?! run is one sentence boundary, not two" ok sentence_count '{"max":2}' \
    'Really?! The deadline moved.'
verdict "an ellipsis run is one sentence boundary, not three" ok sentence_count '{"max":2}' \
    'Wait... The deadline moved.'

# --- non_empty: the single most obvious delegation failure ------------------------
# RED-first: an empty reply scored all-green on every check, in a harness whose stated
# purpose is to prevent "plausible rows, nothing actually asserted".
verdict "an empty reply is not ok" not-ok non_empty '{}' ''
verdict "a whitespace-only reply is not ok" not-ok non_empty '{}' '   '
verdict "an ideographic-space-only reply is not ok" not-ok non_empty '{}' '　'
verdict "a reply with content is ok" ok non_empty '{}' 'The deadline moved.'

# --- no_preamble: the contraction, the anchoring, the alternation -----------------
# RED-first: `here (?:is|are|'"'"'s)` puts the space outside the group, so the branch could
# only ever fire on the impossible "here 's". The commonest English preamble was missed.
verdict "no_preamble refuses the contraction \"Here's a summary\"" not-ok no_preamble '{}' \
    "Here's a summary of the meeting: the deadline moved."
# Kills `.match` -> `.search`. The old anchoring fixture contained no preamble pattern at
# all, so match and search were indistinguishable on it.
verdict "no_preamble is anchored: an opener mid-reply is not flagged" ok no_preamble '{}' \
    'The deadline moved to March. Here is the rest of the detail.'
# RED-first: `當然|当然[，,、:：]` — alternation binds looser than the class, so the
# Traditional form carried no punctuation requirement and flagged ordinary content.
verdict "no_preamble accepts ordinary Traditional content beginning 當然" ok no_preamble '{}' \
    '當然可以達成這個目標。'
verdict "no_preamble refuses 當然， as an opener" not-ok no_preamble '{}' \
    '當然，這是摘要。'
verdict "no_preamble refuses 好的， as an opener" not-ok no_preamble '{}' \
    '好的，以下摘要。'
verdict "no_preamble refuses \"Sure,\" as an opener" not-ok no_preamble '{}' \
    'Sure, here it is.'
verdict "no_preamble refuses \"Below is\" as an opener" not-ok no_preamble '{}' \
    'Below is the summary you asked for.'
verdict "no_preamble refuses \"I have summarized\" as an opener" not-ok no_preamble '{}' \
    'I have summarized the text below.'
# Six of the thirteen preamble patterns had no fixture at all: deleting them one by one
# left the suite green, which is the same "the test cannot fail on its defect" shape as
# everything else in this round. One case each, and each matches only its own pattern.
#
# These earned their keep within the hour. A mutation sweep was killed by a command
# timeout mid-run, leaving check.py with one pattern deleted; the next step copied that
# file as the sweep's new baseline, blessing the mutant. The only thing that noticed was
# the 我(?:已經…) case below — before it existed, that deletion was one of the eleven
# that ran green. A mutation harness that does not restore on interrupt is a way to
# commit a mutant, and the fixtures are what stand between the two.
verdict "no_preamble refuses \"This is a summary\"" not-ok no_preamble '{}' \
    'This is a summary of the meeting.'
verdict "no_preamble refuses \"Let me\"" not-ok no_preamble '{}' \
    'Let me summarize: the deadline moved.'
verdict "no_preamble refuses \"As requested\"" not-ok no_preamble '{}' \
    'As requested, the deadline moved to March.'
verdict "no_preamble refuses 這是一份摘要" not-ok no_preamble '{}' \
    '這是一份摘要：期限延到四月五日。'
verdict "no_preamble refuses 我已經…" not-ok no_preamble '{}' \
    '我已經幫你整理好了。'
verdict "no_preamble refuses 摘要如下" not-ok no_preamble '{}' \
    '摘要如下：期限延到四月五日。'
verdict "no_preamble sees through markdown emphasis on the opener" not-ok no_preamble '{}' \
    '**Here is a summary:** the deadline moved.'

# --- script_purity: both directions, so the set cannot be silently emptied ---------
# RED-first: 紫 (紫色) and 凰 (鳳凰) are the SAME codepoint in both scripts; 划 (划船,
# 划算) and 据 (拮据) are legitimate Traditional characters. All four were flagged,
# violating the direction the README promises in writing.
verdict "script_purity accepts 紫色 (identical in both scripts)" ok script_purity '{"script":"traditional"}' \
    '會議紀錄用紫色標記三項待決事項。'
verdict "script_purity accepts 鳳凰 (identical in both scripts)" ok script_purity '{"script":"traditional"}' \
    '這個專案的代號是鳳凰計畫。'
verdict "script_purity accepts 划算 (a real Traditional character)" ok script_purity '{"script":"traditional"}' \
    '他覺得這樣做並不划算，所以否決了。'
verdict "script_purity accepts 拮据 (a real Traditional word)" ok script_purity '{"script":"traditional"}' \
    '那一年經費拮据。'
# The other direction. These pin the CONTENT of the set: shrink it and these go red,
# which is the mutation that previously survived.
verdict "script_purity refuses 这 (的确是简体)" not-ok script_purity '{"script":"traditional"}' '这是摘要。'
verdict "script_purity refuses 说" not-ok script_purity '{"script":"traditional"}' '他说得很清楚。'
verdict "script_purity refuses 时间" not-ok script_purity '{"script":"traditional"}' '时间不够了。'
verdict "script_purity refuses 实现" not-ok script_purity '{"script":"traditional"}' '这个功能已经实现。'
verdict "script_purity refuses 发现" not-ok script_purity '{"script":"traditional"}' '我们发现了问题。'
verdict "script_purity refuses 关于" not-ok script_purity '{"script":"traditional"}' '关于这个决定。'
verdict "script_purity refuses 应该" not-ok script_purity '{"script":"traditional"}' '应该没有问题。'
verdict "script_purity refuses 结论" not-ok script_purity '{"script":"traditional"}' '结论如下。'

# --- The invariant as a PROPERTY, not a list of examples ---------------------------
# The old version stated "characters valid in both scripts are deliberately left out" in
# a comment and violated it in the data. Big5 is a Traditional-only charset, so "encodes
# in Big5" is the mechanical form of that sentence. Re-adding 紫 / 凰 / 划 / 据 now fails
# here instead of reaching a reviewer.
big5=$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = []
for c in sorted(m._SIMPLIFIED_ONLY):
    try:
        c.encode("big5"); bad.append(c)
    except UnicodeEncodeError:
        pass
print("".join(bad))' "$CHECK" 2>/dev/null)
if [ -z "$big5" ]; then
    echo "  ok   — no member of _SIMPLIFIED_ONLY encodes in Big5 (property, not a list)"
    PASS=$((PASS + 1))
else
    echo "  FAIL — these members of _SIMPLIFIED_ONLY are valid Traditional (Big5): $big5"
    FAIL=$((FAIL + 1))
fi
# The set must also stay non-trivial. Without this, emptying it satisfies the property
# above — the "check that refuses nothing" dual of the trap CLAUDE.md records.
size=$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(len(m._SIMPLIFIED_ONLY))' "$CHECK" 2>/dev/null)
if [ "${size:-0}" -ge 300 ]; then
    echo "  ok   — _SIMPLIFIED_ONLY still holds $size characters (cannot be silently emptied)"
    PASS=$((PASS + 1))
else
    echo "  FAIL — _SIMPLIFIED_ONLY shrank to ${size:-?} characters"
    FAIL=$((FAIL + 1))
fi

# --- category_member: brackets a CJK model actually uses --------------------------
verdict "category_member tolerates CJK corner brackets" ok category_member \
    '{"categories":["bug","feature","question"]}' '「feature」'
verdict "category_member tolerates square brackets" ok category_member \
    '{"categories":["bug","feature","question"]}' '[feature]'
verdict "category_member tolerates markdown bold" ok category_member \
    '{"categories":["bug","feature","question"]}' '**feature**'

# --- guards must actually guard. Kills deletion of the three raise ValueError. -----
guard() {  # guard <description> <check> <expect-json>
    local desc="$1" name="$2" spec="$3"
    if printf 'x' | python3 "$CHECK" --check "$name" --expect "$spec" >/dev/null 2>&1; then
        echo "  FAIL — $desc (exited 0; a malformed expectation was accepted)"; FAIL=$((FAIL + 1))
    else
        echo "  ok   — $desc"; PASS=$((PASS + 1))
    fi
}
guard "sentence_count rejects a missing max"          sentence_count  '{}'
guard "sentence_count rejects a non-integer max"      sentence_count  '{"max":"2"}'
guard "sentence_count rejects a boolean max"          sentence_count  '{"max":true}'
guard "script_purity rejects an unimplemented script" script_purity   '{"script":"simplified"}'
guard "category_member rejects an empty list"         category_member '{"categories":[]}'
guard "category_member rejects a missing list"        category_member '{}'

# --- --spec with a MIXED verdict. Kills all(...) -> any(...). ---------------------
# Every previous --spec fixture was uniformly true or uniformly false, so the two are
# indistinguishable on them.
MIX=$(printf 'The deadline moved. Two people objected. The vote carried.' \
      | python3 "$CHECK" --spec '{"sentence_count":{"max":2},"no_preamble":{}}' 2>&1)
mixed=$(printf '%s' "$MIX" | python3 -c '
import json,sys
d=json.load(sys.stdin)
oks=sorted(c["ok"] for c in d["checks"])
print("%s|%s" % (oks, d["mechanical_ok"]))' 2>/dev/null)
if [ "$mixed" = "[False, True]|False" ]; then
    echo "  ok   — a mixed verdict reports all_ok=false (all(), not any())"
    PASS=$((PASS + 1))
else
    echo "  FAIL — mixed-verdict spec returned '$mixed', expected '[False, True]|False'"
    FAIL=$((FAIL + 1))
fi

# ── rpc.py score: the envelope handling, also hermetic ────────────────────────────
# check.py's verdicts are mutation-proven above, but nothing yet showed that a FAILING
# verdict actually reaches a row. The end-to-end run that motivated these cases came
# back all-green, so the path from "a check said no" to "the row says so" was carried
# entirely by inspection. That is the shape of defect this repo keeps producing: the
# mechanism harmless, the reporting untested. rpc.py score takes a response on stdin
# and needs no model, so it belongs here rather than in the hand-checked half.
RPC="$REPO/scripts/eval/rpc.py"
export RPC
CASES="$REPO/scripts/eval/cases/summarize.json"

# row <description> <expected mechanical_ok: true|false|null> <response-json>
row() {
    local desc="$1" want="$2" resp="$3" out rc got
    out=$(printf '%s' "$resp" | python3 "$RPC" score --case-file "$CASES" --index 0 \
              --model-requested "" --check "$CHECK" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL — $desc (rpc.py score exited $rc: $out)"; FAIL=$((FAIL + 1)); return
    fi
    got=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["mechanical_ok"]))' 2>/dev/null)
    if [ "$got" = "$want" ]; then
        echo "  ok   — $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL — $desc (mechanical_ok was $got, expected $want)"; echo "         $out"; FAIL=$((FAIL + 1))
    fi
}

# A reply that breaks the sentence ceiling AND opens with a preamble must reach the row
# as all_ok=false. Case 0 asks for at most 2 sentences.
row "a violating reply produces mechanical_ok=false" false \
    '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"task\":\"summarize\",\"model\":\"m\",\"elapsed_seconds\":1.0,\"text\":\"Here is a summary of the text: one. Two. Three. Four.\"}"}]}}'
row "a compliant reply produces mechanical_ok=true" true \
    '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"task\":\"summarize\",\"model\":\"m\",\"elapsed_seconds\":1.0,\"text\":\"The deadline moved to 5 April. Funding was approved at 60%.\"}"}]}}'
# A tool error is a RESULT to record, not a harness crash: all_ok stays null and the
# reason is preserved. Scoring it as a pass, or aborting the run, both lose information.
row "a tool error is recorded, not scored" null \
    '{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"Error: could not reach the local server"}]}}'
row "a JSON-RPC error is recorded, not scored" null \
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}'

# --- rpc.py: the paths round 1 left entirely uncovered ----------------------------

# RED-first: `payload.get("text", "")` defaults only on a MISSING key. An explicit JSON
# null returned None, which reached `subprocess.run(input=None)` — and input=None means
# "do not redirect stdin", so check.py inherited the scorer's already-consumed stdin,
# read EOF, and checked the empty string. Every check passed on a null reply.
row "an explicit null text is not silently checked as empty" false \
    '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"model\":\"m\",\"text\":null}"}]}}'

# RED-first: `if not spec: return [], True`. A case with no expectations produced
# checks: [] and a green row — the harness reporting without checking, in its own code.
# non_empty now runs on every case regardless of `expect`, so nothing is vacuously green.
ECASE=$(mktemp "${TMPDIR:-/tmp}/eval-emptyexpect-XXXXXX.json")
cat > "$ECASE" <<'JSON'
{"cases":[{"id":"no-expectations","tool":"local_summarize","arguments":{"text":"x"},"expect":{}}]}
JSON
got=$(printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"model\":\"m\",\"text\":\"   \"}"}]}}' \
      | python3 "$RPC" score --case-file "$ECASE" --index 0 --model-requested "" --check "$CHECK" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["checks"]), d["mechanical_ok"])' 2>/dev/null)
rm -f "$ECASE"
if [ "$got" = "1 False" ]; then
    echo "  ok   — a case with an empty expect still runs non_empty (nothing is vacuously green)"
    PASS=$((PASS + 1))
else
    echo "  FAIL — empty-expect case returned '$got', expected '1 False'"; FAIL=$((FAIL + 1))
fi

# RED-first: local_classify's payload has no `text` key at all — it is
# task/category/matched/raw_response. `payload.get("text","")` handed category_member the
# empty string, which is never in the candidate list, so it would have refused EVERY
# reply: "a check that refuses everything", reproduced one level down in the one check
# with no positive case to catch it.
CCASE=$(mktemp "${TMPDIR:-/tmp}/eval-classify-XXXXXX.json")
cat > "$CCASE" <<'JSON'
{"cases":[{"id":"classify-shape","tool":"local_classify",
  "arguments":{"text":"x","categories":["positive","negative"]},
  "expect":{"category_member":{"categories":["positive","negative"]}}}]}
JSON
cls=$(printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"task\":\"classify\",\"category\":\"negative\",\"matched\":true,\"raw_response\":\"negative\",\"model\":\"m\"}"}]}}' \
      | python3 "$RPC" score --case-file "$CCASE" --index 0 --model-requested "" --check "$CHECK" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["mechanical_ok"], d["text"], d.get("matched"), d.get("category"))' 2>/dev/null)
if [ "$cls" = "True negative True negative" ]; then
    echo "  ok   — a classify payload is scored on raw_response, and matched/category reach the row"
    PASS=$((PASS + 1))
else
    echo "  FAIL — classify row was '$cls', expected 'True negative True negative'"; FAIL=$((FAIL + 1))
fi
# ...and an unmatched classify reply must be visible as such, which is the issue's
# actual question ("whether matched: false fires when it should").
unm=$(printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"task\":\"classify\",\"category\":null,\"matched\":false,\"raw_response\":\"I am not sure about this one.\",\"model\":\"m\"}"}]}}' \
      | python3 "$RPC" score --case-file "$CCASE" --index 0 --model-requested "" --check "$CHECK" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["mechanical_ok"], d.get("matched"))' 2>/dev/null)
rm -f "$CCASE"
if [ "$unm" = "False False" ]; then
    echo "  ok   — an unmatched classify reply is not green, and matched=false reaches the row"
    PASS=$((PASS + 1))
else
    echo "  FAIL — unmatched classify row was '$unm', expected 'False False'"; FAIL=$((FAIL + 1))
fi

# RED-first: an error row dropped model_requested on the default path AND recorded no
# model id at all, against issue #1's "record the model id with EVERY result" — where
# the diff itself decided a tool error IS a result.
errm=$(printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"Error: down"}]}}' \
       | python3 "$RPC" score --case-file "$CASES" --index 0 --model-requested "some-model-id" --check "$CHECK" \
       | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["model_requested"], d["mechanical_ok"] is None)' 2>/dev/null)
if [ "$errm" = "some-model-id True" ]; then
    echo "  ok   — an error row still records which model was asked for"
    PASS=$((PASS + 1))
else
    echo "  FAIL — error row gave '$errm', expected 'some-model-id True'"; FAIL=$((FAIL + 1))
fi

# --- rpc.py request: the mechanism the whole cross-size requirement rests on -------
# RED-first: covered by nothing. Delete the two lines that inject the override and every
# test stayed green while `make eval MODELS="--model a --model b"` silently ran the same
# model twice — the requirement reported as satisfied, measuring nothing.
req=$(python3 "$RPC" request --case-file "$CASES" --index 0 --id 7 --model "some-model-id" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["params"]["arguments"].get("model"), d["id"], d["params"]["name"])' 2>/dev/null)
if [ "$req" = "some-model-id 7 local_summarize" ]; then
    echo "  ok   — request injects the model override into the tool arguments"
    PASS=$((PASS + 1))
else
    echo "  FAIL — request produced '$req', expected 'some-model-id 7 local_summarize'"; FAIL=$((FAIL + 1))
fi
noreq=$(python3 "$RPC" request --case-file "$CASES" --index 0 --id 7 --model "" \
        | python3 -c 'import json,sys; print("model" in json.load(sys.stdin)["params"]["arguments"])' 2>/dev/null)
if [ "$noreq" = "False" ]; then
    echo "  ok   — no override means no model key, so the server picks"
    PASS=$((PASS + 1))
else
    echo "  FAIL — empty override still set a model key"; FAIL=$((FAIL + 1))
fi

# --- the fields the row exists to carry -------------------------------------------
# RED-first: dropping finish_reason / elapsed_seconds / model / why from the row left the
# suite green. A truncated reply and an instruction-ignoring reply are different findings.
fields=$(printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"model\":\"served-id\",\"elapsed_seconds\":2.5,\"finish_reason\":\"length\",\"text\":\"One.\"}"}]}}' \
         | python3 "$RPC" score --case-file "$CASES" --index 0 --model-requested "asked-id" --check "$CHECK" \
         | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["model"], d["elapsed_seconds"], d["finish_reason"], bool(d["why"]))' 2>/dev/null)
if [ "$fields" = "served-id 2.5 length True" ]; then
    echo "  ok   — model / elapsed_seconds / finish_reason / why all reach the row"
    PASS=$((PASS + 1))
else
    echo "  FAIL — row fields were '$fields', expected 'served-id 2.5 length True'"; FAIL=$((FAIL + 1))
fi

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

# --- rpc.py summarize: the guard that failed, made testable -----------------------
# The guard used to be inline bash counting rows APPENDED, with the comment "a green eval
# that ran no cases is the reporting-without-checking failure in its purest form". A
# recorded tool error is a row, so a run where every single call failed printed
# "5 row(s) written, 0 error(s)" and exited 0 — the harness failing open on precisely the
# state it was written to detect, reproduced against the real binary.
#
# It now lives here as a pure function of the output file, so it can be tested at all.
sumjson() {  # sumjson <description> <expected exit> <expected measured> <jsonl body>
    local desc="$1" want_rc="$2" want_measured="$3" body="$4"
    local f out rc measured
    f=$(mktemp "${TMPDIR:-/tmp}/eval-sum-XXXXXX.jsonl")
    printf '%s' "$body" > "$f"
    out=$(python3 "$RPC" summarize --out "$f" 2>&1); rc=$?
    measured=$(printf '%s' "$out" | sed -nE 's/.*measured=([0-9]+).*/\1/p' | head -1)
    rm -f "$f"
    if [ "$rc" = "$want_rc" ] && [ "${measured:-x}" = "$want_measured" ]; then
        echo "  ok   — $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL — $desc (rc=$rc measured=${measured:-?}, wanted rc=$want_rc measured=$want_measured)"
        echo "         $out"; FAIL=$((FAIL + 1))
    fi
}
# The reproduction from the verify report: five rows, every one a recorded tool error.
sumjson "all-errors run exits non-zero and reports measured=0" 1 0 \
'{"case":"a","error":"Error: down","mechanical_ok":null,"checks":[]}
{"case":"b","error":"Error: down","mechanical_ok":null,"checks":[]}
'
sumjson "an empty output file exits non-zero" 1 0 ''
sumjson "two measured replies exit zero" 0 2 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[{"check":"non_empty","ok":true}],"human_review":["x"]}
{"case":"b","error":null,"mechanical_ok":false,"checks":[{"check":"non_empty","ok":false}],"human_review":["y"]}
'
# Measured and errored must be reported separately: "N rows, 0 errors" could not tell a
# run of N real replies from a run of N recorded failures. A partial run is also not a
# green run — exit is non-zero, matching the original `ERRORS -eq 0 || exit 1` intent.
# (This expectation was wrong on first writing: it asserted rc=0. The implementation was
# right and the test was not, so the test moved. Recorded because "fix the code until the
# test passes" is the reflex this repo's history keeps punishing.)
sumjson "a mixed run counts measured separately and is not green" 1 1 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[],"human_review":[]}
{"case":"b","error":"Error: down","mechanical_ok":null,"checks":[]}
'
# human_review is the half issue #1 asks NOT to be auto-judged, and run.sh never printed
# it — `grep -n human_review scripts/eval/run.sh` was zero hits. The questions were
# carried into the file and then never put in front of anyone.
hr=$(python3 - <<'INNER'
import json, subprocess, sys, tempfile, os
rows = [{"case":"a","error":None,"mechanical_ok":True,"checks":[],
         "human_review":["Coverage: did the three items survive?"]}]
f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
for r in rows: f.write(json.dumps(r) + "\n")
f.close()
out = subprocess.run([sys.executable, os.environ["RPC"], "summarize", "--out", f.name],
                     capture_output=True, text=True).stdout
os.unlink(f.name)
print("YES" if "did the three items survive" in out else "NO")
INNER
)
if [ "$hr" = "YES" ]; then
    echo "  ok   — summarize puts the human_review questions in front of the operator"
    PASS=$((PASS + 1))
else
    echo "  FAIL — human_review never reaches the terminal"; FAIL=$((FAIL + 1))
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
