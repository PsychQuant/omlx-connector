#!/bin/bash
# Unit tests for scripts/eval/check.py — the mechanical checks used by `make eval`.
#
# WHAT THIS SUITE IS: self-contained, not network-free. check.py is pure text processing
# and most cases here are that. But this file also binds an ephemeral 127.0.0.1 socket
# (scripts/tests/stubs/fake-omlx.py) so the REAL binary's response parsing can be
# exercised, drives scripts/eval/run.sh end to end against a stub MCP, and re-invokes
# itself against mutated copies of check.py. No oMLX, no model, no off-box traffic — and
# an earlier header said "no network" for three rounds after that stopped being true,
# which CLAUDE.md names as the message-shaped bug this repo keeps producing.
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
RPC="$REPO/scripts/eval/rpc.py"
export RPC
# CANARY MODE: this suite re-invokes itself against a deliberately broken copy of check.py
# and requires a pinned number of its own assertions to fail. See THE CANARY below. In this
# mode only the check-level cases run, and the trap prints how many failed instead of
# judging the count.
CANARY_MODE=""
if [ -n "${EVAL_CHECKS_CANARY:-}" ]; then
    # Only with the run's own token, and only if that token is written INSIDE the file the
    # variable points at. Round 5's verify set EVAL_CHECKS_CANARY in the ambient environment,
    # pointing at the real check.py: the suite ran 186 assertions, skipped its count, printed
    # CANARY_FAILS=0 and exited 0 — the mechanism shipping its own bypass. The parent writes a
    # per-run token into every mutant it builds; nothing else can produce a matching file.
    if [ -z "${EVAL_CHECKS_CANARY_TOKEN:-}" ] || \
       ! grep -q "^# canary-token: ${EVAL_CHECKS_CANARY_TOKEN}\$" "$EVAL_CHECKS_CANARY" 2>/dev/null; then
        echo "  FAIL — EVAL_CHECKS_CANARY is set but carries no matching per-run token; refusing canary mode" >&2
        exit 1
    fi
    CHECK="$EVAL_CHECKS_CANARY"
    CANARY_MODE=1
fi
PASS=0
FAIL=0
SKIP=0

# One directory per run, plain filenames inside. The previous form called
# `mktemp "$TMPDIR/eval-sum-XXXXXX.jsonl"` — and macOS mktemp does NOT substitute when the
# X's are not the final characters: it creates the LITERAL name, so the path was fixed,
# shared between concurrent runs and between repos, and a single leftover turned this
# suite from 89/0 into 82/7. `mktemp -d` has the X's last, so it is genuinely unique.
SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/eval-checks.XXXXXX")
# FAKE_PID is registered here rather than only killed inline: round 3 sent SIGTERM to the
# suite mid-run and `fake-omlx.py` — which calls serve_forever() with no timeout — was still
# listening on loopback minutes later and had to be killed by hand. Any exit between spawn
# and the inline kill leaked it permanently.
FAKE_PID=""

# THE ACCOUNTING RUNS IN THE EXIT TRAP, NOT AT THE BOTTOM OF THE FILE.
#
# Round 4 put the self-count at the end of the file and called it "where the recursion
# stops". Round 4's verify then removed python3 from PATH: the suite took an early
# `exit 0` on line ~90, the count on line ~1156 was never evaluated, and `make test` was
# green with zero assertions run. A guard that sits after every early exit guards nothing
# that exits early. Every path out of this script — first line or last — goes through here.
#
# EXPECTED_CASES counts PASS + FAIL only. A SKIP is not a third kind of result in this
# suite: every dependency it has (python3, the stubs, the built binary) is the repo's own,
# so a skip means "this machine is not set up to run the suite", and that is a failure with
# a message, not a pass with a footnote. Round 4 also found that the fake-oMLX block
# contributed exactly one unit to the count whether it ran or skipped, so the only test able
# to see the served-model call site could vanish silently.
EXPECTED_CASES=326       # updated ON PURPOSE when a case is added or removed — see the tail
finish_suite() {
    local rc=0
    [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
    rm -rf "$SUITE_TMP"
    if [ -n "$CANARY_MODE" ]; then
        echo "CANARY_FAILS=$FAIL"
        exit 0
    fi
    echo
    echo "  $PASS passed, $FAIL failed, $SKIP skipped"
    local ran=$((PASS + FAIL))
    if [ "$ran" -ne "$EXPECTED_CASES" ]; then
        echo "  FAIL — suite ran $ran assertion(s), expected $EXPECTED_CASES."
        if [ "$SKIP" -gt 0 ]; then
            echo "         $SKIP case(s) skipped. This suite has no legitimate skips — its dependencies"
            echo "         are the repo's own (python3, scripts/tests/stubs/, .build/debug/). Build first."
        else
            echo "         A guard was added or removed. If deliberate, update EXPECTED_CASES;"
            echo "         if not, something deleted coverage and every remaining case still passed."
        fi
        rc=1
    fi
    [ "$FAIL" -eq 0 ] || rc=1
    exit "$rc"
}
trap finish_suite EXIT

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

# Not a skip. Without python3 nothing below can run, and "nothing ran" is a failure — the
# round-4 verify reached exit 0 through exactly this branch. The EXIT trap would catch the
# zero count anyway; saying so here is cheaper than making a reader work that out.
command -v python3 >/dev/null 2>&1 || {
    echo "  FAIL — python3 not available: every assertion in this suite needs it, and none ran"
    FAIL=$((FAIL + 1)); exit 1
}
[ -f "$CHECK" ] || { echo "  FAIL — $CHECK does not exist"; FAIL=$((FAIL + 1)); exit 1; }

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

# Kills shrinking _TERMINATORS. No fixture used ？ or ！ as a terminator — in a harness
# whose Chinese case asks for 繁體中文 output. Reducing ".!?。！？…" to ".!?。" left the
# suite green while a three-sentence Chinese reply started counting as one.
verdict "？ terminates a sentence" not-ok sentence_count '{"max":2}' \
    '這樣可以嗎？我們決定延後！請看附件。'
verdict "！ and ？ together are three sentences, not one" ok sentence_count '{"max":3}' \
    '這樣可以嗎？我們決定延後！請看附件。'
verdict "… terminates a sentence" not-ok sentence_count '{"max":1}' \
    '他猶豫了…最後還是同意了。'
# ASCII ! and ? were unpinned in round 3: every fixture used a fullwidth form or a RUN
# (`Really?!`), and a run is collapsed, so deleting either from _TERMINATORS survived.
verdict "ASCII ! terminates a sentence" not-ok sentence_count '{"max":1}' \
    'The deadline moved! The vote carried.'
verdict "ASCII ? terminates a sentence" not-ok sentence_count '{"max":1}' \
    'Did the deadline move? It did.'

# Kills stripping the whitespace out of _CLOSERS. A reply ending in a newline is the
# commonest model output shape there is, and no fixture had one: every tail-rule fixture
# ended on a bare terminator, a quote, a bracket, `**` or a word.
verdict "a trailing newline is not a new sentence" ok sentence_count '{"max":2}' \
    'One. Two.
'
verdict "a trailing ideographic space is not a new sentence" ok sentence_count '{"max":1}' \
    '期限延到四月五日。　'

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

# --- no_preamble as a CLASS, not a list of instances -------------------------------
# Round 1 found `當然|当然[，,、:：]` mis-parsing. Round 2 fixed THAT LINE and gave it two
# fixtures — and left `我(?:已經|會|來|將)` one line below with the identical shape, and
# `i(?:'ve| have| will| ?'ll)` with it. Both fire on any reply merely beginning in the first
# person. That is the "fix the property, not the file" section of CLAUDE.md, violated by the
# round that cited it.
#
# So the guard is now a CORPUS, not another instance. Anything that reads as ordinary
# content must survive every pattern; anything that reads as a lead-in must be caught by
# some pattern. Adding a pattern means adding to both lists, and a pattern that flags
# ordinary content fails here no matter which line it was written on.
corpus() {  # corpus <expected: ok|not-ok> <label> <text...>
    local want="$1" label="$2"; shift 2
    local bad=0 t v
    for t in "$@"; do
        v=$(printf '%s' "$t" | python3 "$CHECK" --check no_preamble --expect '{}' \
            | python3 -c 'import json,sys; print("ok" if json.load(sys.stdin)["ok"] else "not-ok")' 2>/dev/null)
        if [ "$v" != "$want" ]; then
            [ "$bad" -eq 0 ] && echo "  FAIL — $label"
            echo "         $t  → $v (wanted $want)"
            bad=$((bad + 1))
        fi
    done
    # ONE ASSERTION PER FIXTURE. As one assertion per loop, hollowing a 21-entry corpus to a
    # single entry left both the count and every canary unchanged — the DA's third
    # weakening mutation. Counting per fixture binds EXPECTED_CASES and the canaries to the
    # number of fixtures, which is the quantity that hollowing changes.
    PASS=$((PASS + $# - bad)); FAIL=$((FAIL + bad))
    [ "$bad" -eq 0 ] && echo "  ok   — $label ($# fixtures)"
}

corpus ok "no pattern flags ordinary content (false-positive corpus)" \
    'I will attend the meeting on Tuesday.' \
    'I have three concerns about the timeline.' \
    "I'll send the revised figures tomorrow." \
    '我會在下週提出報告。' \
    '我將期限延到四月五日。' \
    '我來自台北，負責這個專案。' \
    '我已經完成了三項工作。' \
    '當然可以達成這個目標。' \
    '好的消息是期限延後了。' \
    '這是第三次修訂。' \
    'Below the surface the data disagrees.' \
    'Three items were deferred: budget, venue, and the vote.' \
    'The deadline moved to March. Here is the rest of the detail.' \
    '總結報告會在週五送出。' \
    'Sure enough, the deadline slipped again.' \
    '我會整理房間，然後出門。' \
    '我已經整理好行李了。' \
    '我來回答你的第一個問題。' \
    '我將整理這批資料的索引。' \
    'I have attached the figures below.' \
    'I will meet you below the bridge at noon.' \
    'I have three concerns, as follows.' \
    'Of course, the deadline had already slipped.' \
    'Let me know if the deadline changes.' \
    'This is the result of an expired TLS certificate: renewal is automated, but the cron entry had been removed.' \
    '我會幫你確認會議時間，並在今天下班前回覆。' \
    '我來幫你買咖啡。' \
    '我將為你保留一個位置。' \
    '我會在明天幫你完成報告。' \
    '我來幫你做好準備。' \
    '我將幫你寫好推薦信。'

corpus not-ok "every known lead-in is still caught (true-positive corpus)" \
    'Here is a summary of the text: the deadline moved.' \
    "Here's a summary of the meeting: the deadline moved." \
    'Below is the summary you asked for.' \
    'The following is a summary of the discussion.' \
    'This is a summary of the meeting.' \
    'Let me summarize: the deadline moved.' \
    'As requested, the deadline moved to March.' \
    'Sure, here it is.' \
    'Certainly! The deadline moved to March.' \
    'I have summarized the text below.' \
    'I will summarize the discussion as follows.' \
    '以下是這段文字的摘要：期限延到三月。' \
    '這是一份摘要：期限延到四月五日。' \
    '好的，以下摘要。' \
    '當然，這是摘要。' \
    '我已經幫你整理好了。' \
    '摘要如下：期限延到四月五日。' \
    '**Here is a summary:** the deadline moved.' \
    'Of course! Here is the summary: the deadline moved.' \
    '我已經把摘要整理好了：期限延到四月五日。' \
    '我已經幫你把報告寫好了。'

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

# --- script_purity: two corpora, because the question is linguistic, not computable ----
# Round 2 replaced a prose promise with a Big5 property test, on the theory that Big5 being
# a Traditional-only charset made "encodes in Big5" the mechanical form of "is valid
# Traditional". It is not. Big5 also carries rare ARCHAIC variants of characters that are
# plain Simplified markers in any modern text, so the property removed sixteen real
# detections along with the four genuine false-positive sources — and then made that
# irreversible. `什么` began passing silently.
#
# Whether a character is Simplified-only is a fact about language. So the guard is two
# corpora, and the Simplified one is sampled to touch EVERY line of the set: round 2 found
# that eight of ten lines could be deleted individually with the suite still green, because
# a table's power was pinned only by whichever characters happened to appear in a fixture.
scorpus() {  # scorpus <expected: ok|not-ok> <label> <text...>
    local want="$1" label="$2"; shift 2
    local bad=0 t v
    for t in "$@"; do
        v=$(printf '%s' "$t" | python3 "$CHECK" --check script_purity --expect '{"script":"traditional"}' \
            | python3 -c 'import json,sys; print("ok" if json.load(sys.stdin)["ok"] else "not-ok")' 2>/dev/null)
        if [ "$v" != "$want" ]; then
            [ "$bad" -eq 0 ] && echo "  FAIL — $label"
            echo "         $t  → $v (wanted $want)"
            bad=$((bad + 1))
        fi
    done
    # ONE ASSERTION PER FIXTURE. As one assertion per loop, hollowing a 21-entry corpus to a
    # single entry left both the count and every canary unchanged — the DA's third
    # weakening mutation. Counting per fixture binds EXPECTED_CASES and the canaries to the
    # number of fixtures, which is the quantity that hollowing changes.
    PASS=$((PASS + $# - bad)); FAIL=$((FAIL + bad))
    [ "$bad" -eq 0 ] && echo "  ok   — $label ($# fixtures)"
}

# Clean Traditional. Includes the four characters round 1 wrongly flagged, so that
# regression cannot come back.
scorpus ok "clean Traditional is never flagged" \
    '會議紀錄用紫色標記三項待決事項。' \
    '這個專案的代號是鳳凰計畫。' \
    '他覺得這樣做並不划算，所以否決了。' \
    '那一年經費拮据。' \
    '團隊同意把投稿期限延到四月五日。' \
    '第二位研究助理的經費核准了六成。' \
    '兩位成員反對取消控制組，決定延到下週再議。' \
    '網路連線在九點十四分中斷。' \
    '這份報告的結論需要重新檢視。' \
    '他們對這個問題的看法並不一致。' \
    'The deadline moved to 5 April.'

# Simplified words. These exercise realistic input, but they do NOT pin the table: each
# sentence carries characters from several lines, so deleting one line leaves another
# character to flag the same sentence. Six of nine lines survived deletion when this was
# the only coverage — measured, not assumed. The per-character probe below is what
# actually pins it.
scorpus not-ok "Simplified is caught, with every line of the set represented" \
    '这个决定很重要。'     '结论如下。'         '庄园的门口。' \
    '应该没有问题。'       '货币政策改变了。'   '软件已经更新。' \
    '门口有人在等。'       '问题出在时间。'     '龙头企业。' \
    '他听到了什么？'       '网络连接失败。'     '情况很复杂。' \
    '我们发现了问题。'     '关于这个决定。'     '他说得很清楚。' \
    '时间不够了。'         '这个功能已经实现。' '圣人也会犯错。' \
    '东西坏了。'           '宁静的下午。'       '他怀疑这个结论。'


# PER-CHARACTER probes: one from every line of _SIMPLIFIED_ONLY, tested ALONE so that each
# is the sole possible offender. Delete a line and its probe goes green — the mutation the
# word-level corpus above could not see.
probes="这结医应货软门风龙"
bad=""
i=0
while [ $i -lt ${#probes} ]; do
    ch=$(printf '%s' "$probes" | cut -c $((i+1)))
    v=$(printf '%s' "$ch" | python3 "$CHECK" --check script_purity --expect '{"script":"traditional"}' \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)
    [ "$v" = "False" ] || bad="$bad$ch"
    i=$((i + 1))
done
# One assertion per probe, for the same reason corpus() counts per fixture.
nbad=${#bad}
PASS=$((PASS + ${#probes} - nbad)); FAIL=$((FAIL + nbad))
if [ "$nbad" -eq 0 ]; then
    echo "  ok   — every per-line probe character is detected (${#probes} probes, one per line)"
else
    echo "  FAIL — these probe characters are no longer detected: $bad"
fi

# ...and the probe list must keep covering every line, or the guard above weakens silently
# as the table is re-wrapped. This pairs the corpus to the table instead of trusting that
# they stayed in sync — the sync is exactly what broke while writing this round.
# ROUND 3 FOUND THIS GUARD FAILING OPEN ON EXACTLY WHAT IT EXISTS TO DETECT. Its stated
# purpose was "the probe list must keep covering every line, or the guard weakens silently
# as the table is re-wrapped" — and re-wrapping the table to a single-line `set("…")` broke
# the regex, which raised AttributeError, which produced empty stdout, which the `-z` test
# read as success. Empty output must never be the pass signal for a parser that can crash.
uncovered=$(python3 -c '
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"_SIMPLIFIED_ONLY = set\(\s*((?:.|\n)*?)\)\n", src)
if not m:
    print("PARSE-FAILED"); raise SystemExit
lines = re.findall(r"\"([^\"]*)\"", m.group(1))
if not lines:
    print("PARSE-FAILED"); raise SystemExit
probes = set(sys.argv[2])
missing = [str(i) for i, L in enumerate(lines) if not (set(L) & probes)]
print("OK" if not missing else ",".join(missing))' "$CHECK" "$probes" 2>&1)
if [ "$uncovered" = "OK" ]; then
    echo "  ok   — every line of _SIMPLIFIED_ONLY has a probe (deleting any line goes red)"
    PASS=$((PASS + 1))
else
    echo "  FAIL — probe coverage check said: $uncovered"
    echo "         (PARSE-FAILED means the table was re-wrapped and this guard could not read it —"
    echo "          which is the exact edit it exists to catch, so it is a failure, not a pass.)"
    FAIL=$((FAIL + 1))
fi

# THE ADD DIRECTION. Everything above pins DELETION — probes and corpora all prove that
# removing something goes red. Adding is invisible, and adding is the direction that
# produces false positives, which README calls the more damaging one. Round 3 measured it:
# appending an ordinary word to the Chinese meta list, or 繁體字 to the Simplified set,
# produced false positives on clean text with the suite still fully green.
#
# So: a body of clean Traditional prose that no member of _SIMPLIFIED_ONLY may appear in.
# That is a property over the table rather than a list of sentences — adding any character
# that occurs in ordinary Traditional writing fails here regardless of which line it went on.
CLEAN_TRADITIONAL='這份報告的結論需要重新檢視。團隊同意把投稿期限從三月十五日延到四月五日，因為前導資料延遲送達。
第二位研究助理的經費核准了申請金額的六成，兩位成員反對取消控制組，這項決定延到下週再議。
會議紀錄用紫色標記三項待決事項，專案代號是鳳凰計畫。他覺得這樣做並不划算，那一年經費拮据。
網路連線在九點十四分中斷，因為憑證過期；更新原本是自動的，但排程項目在一次無關的清理中被移除了。
我會在下週提出報告，並且說明為什麼這個變更值得做。謝謝大家的協助與體諒。
繁體字的書寫習慣、標點使用與語氣，都應該保持一致。
我會處理這件事，並在完成後通知你。我已經說明過原因了，也回答了所有問題。
我來自台北，我將整理這批資料的索引，之後會把結果寄給你。'

# HONEST LIMIT, because round 3 caught the previous version of this claim overreaching.
# These two checks are CORPORA, so they close the shapes the prose above contains, not the
# property "no pattern ever flags ordinary content". Injecting a meta-list entry whose false
# positives happen to fall outside this text still passes — measured, not assumed. Widen the
# prose when you touch either table; do not read a green run here as proof the class is shut.
bad=$(python3 - "$CHECK" "$CLEAN_TRADITIONAL" <<'INNER'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("".join(sorted({c for c in sys.argv[2] if c in m._SIMPLIFIED_ONLY})))
INNER
)
# Counted PER SENTENCE of the prose, not once per guard. Round 5's verify hollowed this
# prose to one sentence and the count, and all three canaries, stayed exactly where they
# were — then added 謝 to the set and watched 「謝謝大家的協助與體諒。」 get flagged in green.
NSENT=$(printf '%s' "$CLEAN_TRADITIONAL" | python3 -c 'import re,sys; print(sum(1 for l in sys.stdin.read().splitlines() for x in re.split(r"[。！？]", l) if x.strip()))')
if [ -z "$bad" ]; then
    echo "  ok   — no member of _SIMPLIFIED_ONLY occurs in clean Traditional prose ($NSENT sentences)"
    PASS=$((PASS + NSENT))
else
    echo "  FAIL — these members of _SIMPLIFIED_ONLY occur in ordinary Traditional text: $bad"
    FAIL=$((FAIL + ${#bad})); PASS=$((PASS + NSENT > ${#bad} ? NSENT - ${#bad} : 0))
fi

# The same direction for the preamble patterns: no pattern may match the clean corpus.
# `corpus ok` above already does this, but only for the strings it enumerates; this checks
# every SENTENCE of the prose above, which is a wider and independently-maintained body.
badp=$(python3 - "$CHECK" "$CLEAN_TRADITIONAL" <<'INNER'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
hits = []
for line in sys.argv[2].splitlines():
    for sentence in re.split(r"[。！？\n]", line):
        sentence = sentence.strip()
        if sentence and not m.check_no_preamble(sentence, {})["ok"]:
            hits.append(sentence[:24])
print(" | ".join(hits))
INNER
)
if [ -z "$badp" ]; then
    echo "  ok   — no preamble pattern matches clean Traditional prose ($NSENT sentences)"
    PASS=$((PASS + NSENT))
else
    nbadp=$(printf '%s' "$badp" | awk -F' [|] ' '{print NF}')
    echo "  FAIL — preamble patterns flag ordinary Traditional sentences: $badp"
    FAIL=$((FAIL + nbadp)); PASS=$((PASS + (NSENT > nbadp ? NSENT - nbadp : 0)))
fi

# PER-CHARACTER membership, not per-line. Round 3's probes are one per line, so deleting a
# single character was invisible — including 么, the character whose removal was round 2's
# headline regression (什么 passing silently).
missing=$(python3 - "$CHECK" <<'INNER'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
must = "么听圣坏复宁庄怀惊扑扰网胜赶适吨这说时实发关应结国学对会门长问风飞鱼鸟龙齐题预领"
print("".join(c for c in must if c not in m._SIMPLIFIED_ONLY))
INNER
)
NMUST=43   # the length of `must` above; per-character so removing one marker is one red
if [ -z "$missing" ]; then
    echo "  ok   — every named high-frequency Simplified marker is still in the set ($NMUST probes)"
    PASS=$((PASS + NMUST))
else
    echo "  FAIL — these Simplified markers were removed from the set: $missing"
    FAIL=$((FAIL + ${#missing})); PASS=$((PASS + NMUST - ${#missing}))
fi
# ...and the four that must stay OUT, so round 1's false positives cannot return.
back=$(python3 - "$CHECK" <<'INNER'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("chk", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("".join(c for c in "紫凰划据" if c in m._SIMPLIFIED_ONLY))
INNER
)
if [ -z "$back" ]; then
    echo "  ok   — the four Traditional characters round 1 wrongly flagged are still out (4 probes)"
    PASS=$((PASS + 4))
else
    echo "  FAIL — these Traditional characters are back in the set: $back"
    FAIL=$((FAIL + ${#back})); PASS=$((PASS + 4 - ${#back}))
fi

# --- category_member: brackets a CJK model actually uses --------------------------
verdict "category_member tolerates CJK corner brackets" ok category_member \
    '{"categories":["bug","feature","question"]}' '「feature」'
verdict "category_member tolerates square brackets" ok category_member \
    '{"categories":["bug","feature","question"]}' '[feature]'
verdict "category_member tolerates markdown bold" ok category_member \
    '{"categories":["bug","feature","question"]}' '**feature**'
# Round 4: _TRAILING_PUNCT was applied to the reply but not the candidates, so a model
# copying `feature request (UI)` exactly as the tool's prompt instructs was scored a
# violation. Round 5 normalized both sides — and wrote no fixture for it, so the sweep
# could revert the candidate side and stay green.
verdict "category_member: a candidate ending in a bracket matches its verbatim copy" ok category_member \
    '{"categories":["feature request (UI)","bug (crash)"]}' 'feature request (UI)'
verdict "label_is: a gold label ending in punctuation matches its verbatim copy" ok label_is \
    '{"expected":"N/A."}' 'N/A.'

# --- label_is: the labelled set that was there all along ---------------------------
# Round 2: `classify.json` and README both said automating label accuracy "needs a labelled
# set this repo does not have" — two lines above `"Correctness: the answer should be
# `bug`."` The labels existed; they were written as PROSE in human_review instead of as
# data in `expect`. On the live rows the 0.6B answered `feature request` where that case's
# own gold is `bug`, and the row read mechanical_ok: true.
#
# (The round-2 finding also said no check can see gold data because check.py's contract is
# text-in/verdict-out. That part is wrong — `expect` is exactly that channel, and it was
# always passed to every check. The defect was real; its stated mechanism was not.)
verdict "label_is accepts the gold label"            ok     label_is '{"expected":"bug"}' 'bug'
verdict "label_is refuses a different label"         not-ok label_is '{"expected":"bug"}' 'feature request'
verdict "label_is is case- and punctuation-tolerant" ok     label_is '{"expected":"bug"}' '「Bug」'
verdict "label_is refuses a sentence containing it"  not-ok label_is '{"expected":"bug"}' 'I would say this is a bug.'
guard_late() { :; }

# --- usage errors exit 64 in EVERY program, not just run.sh --------------------------
# Round 3 found usage errors exiting 2 (the contract's "ran fine, findings"). Round 4 fixed
# run.sh and left check.py and rpc.py at 2, with check.py's docstring documenting the
# collision as intentional — and the run.sh change itself had no test.
usage64() {  # usage64 <description> <command...>
    local desc="$1"; shift
    "$@" >/dev/null 2>&1; local rc=$?
    if [ "$rc" = "64" ]; then echo "  ok   — $desc"; PASS=$((PASS + 1))
    else echo "  FAIL — $desc (exit $rc, wanted 64)"; FAIL=$((FAIL + 1)); fi
}
usage64 "check.py: unknown check name is a usage error"   python3 "$CHECK" --check no_such_check --expect '{}' --text-file /dev/null
usage64 "check.py: malformed --expect is a usage error"   python3 "$CHECK" --check sentence_count --expect '{' --text-file /dev/null
usage64 "check.py: unknown flag is a usage error"         python3 "$CHECK" --bogus
usage64 "rpc.py: unknown subcommand is a usage error"     python3 "$RPC" bogus
usage64 "rpc.py: unknown flag is a usage error"           python3 "$RPC" summarize --bogus
usage64 "run.sh: unknown flag is a usage error"           "$REPO/scripts/eval/run.sh" --bogus
usage64 "run.sh: a missing option value is a usage error" "$REPO/scripts/eval/run.sh" --model
usage64 "run.sh: a non-numeric timeout is a usage error"  env OMLX_EVAL_TIMEOUT=abc "$REPO/scripts/eval/run.sh"
# A9: the same model or case file twice is a usage error, not a doubled run. Round 4 found
# `--model stub --model stub` producing 10 rows at exit 0, the accounting consistent with
# itself because both the preflight and the run read the same duplicated array.
usage64 "run.sh: the same model twice is a usage error"   "$REPO/scripts/eval/run.sh" --model a --model a
usage64 "run.sh: the same case file twice is a usage error" "$REPO/scripts/eval/run.sh" --model a \
    --cases "$REPO/scripts/eval/cases/summarize.json" --cases "$REPO/scripts/eval/cases/summarize.json"
# Round 5 deduplicated by realpath, which is a spelling of the property, not the property: a
# byte-identical copy, or a hard link, doubled the run with self-consistent books. The
# property is "the same case id twice", checked across every file at preflight.
cp "$REPO/scripts/eval/cases/summarize.json" "$SUITE_TMP/copy-of-summarize.json"
usage64 "run.sh: the same case id in two files is a usage error" "$REPO/scripts/eval/run.sh" --model a \
    --cases "$REPO/scripts/eval/cases/summarize.json" --cases "$SUITE_TMP/copy-of-summarize.json"

# --- guards must actually guard. Kills deletion of the three raise ValueError. -----
# Requires 64, not merely non-zero. The round-5 sweep deleted label_is's gold guard and the
# suite stayed green: with the guard gone the check CRASHED (AttributeError, exit 1), and a
# helper that accepts any non-zero exit cannot tell a refusal from a crash — which is the
# distinction check.py's own docstring draws.
guard() {  # guard <description> <check> <expect-json>
    local desc="$1" name="$2" spec="$3" rc
    printf 'x' | python3 "$CHECK" --check "$name" --expect "$spec" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "64" ]; then
        echo "  ok   — $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL — $desc (exit $rc, wanted 64: a malformed expectation is a usage error, not a crash)"; FAIL=$((FAIL + 1))
    fi
}
guard "sentence_count rejects a missing max"          sentence_count  '{}'
guard "sentence_count rejects a non-integer max"      sentence_count  '{"max":"2"}'
guard "sentence_count rejects a boolean max"          sentence_count  '{"max":true}'
guard "script_purity rejects an unimplemented script" script_purity   '{"script":"simplified"}'
guard "category_member rejects an empty list"         category_member '{"categories":[]}'
guard "category_member rejects a missing list"        category_member '{}'
guard "label_is rejects a missing expected"           label_is        '{}'
guard "label_is rejects an empty expected"            label_is        '{"expected":"  "}'

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

# ══ THE CANARY ═══════════════════════════════════════════════════════════════════════
#
# Everything above is a check-level assertion against $CHECK. In canary mode that is all
# that runs, and the trap prints how many failed. Stop here in that mode — the block below
# would recurse.
if [ -n "$CANARY_MODE" ]; then exit 0; fi

# The count (EXPECTED_CASES) catches DELETION. Round 4's verify showed it cannot catch
# WEAKENING: neuter the assertion helper (`if [ "$actual" = "$expect" ]` → `if true`) and this
# file stays at its full count, byte-identical to baseline, while a defect seeded into
# check.py that 11 cases used to catch is caught by 2. Move a boundary fixture back off the
# boundary: same count. Hollow a 21-entry corpus to one: same count. The number counts
# PASS++ calls, not what each call asserted.
#
# The only thing that can see weakening is running the suite against something broken and
# requiring it to notice — which is what the offline mutation sweep does, and why the sweep
# kept finding what the suite could not. So a miniature of the sweep lives here. Three
# mutants of check.py, built fresh each run; the suite re-invokes itself against each and
# must fail EXACTLY the pinned number of times:
#
#   always-ok     every check says ok    → pins the not-ok fixtures AND the helper
#   always-notok  every check says not-ok → pins the ok fixtures
#   off-by-one    `<= ceiling` → `<= ceiling + 1` → pins the BOUNDARY fixtures, the ones
#                 the header of this file forbids moving and no count could see
#
# The three constants are updated ON PURPOSE when fixtures change, like EXPECTED_CASES.
#
# WHAT THE CANARY DOES NOT SEE — measured in round 5, not estimated. A canary only sees an
# assertion whose verdict FLIPS under one of the three mutants of check.py. That leaves two
# blind families:
#   1. everything after the canary exit below never runs in canary mode at all — the
#      rpc.py score / summarize / complete / append cases, run.sh end-to-end, the manifest,
#      the served-model call site (62 of 248 assertions in round 5);
#   2. assertions that check an EXIT CODE or a table's MEMBERSHIP rather than a verdict —
#      usage64(), guard(), the probe-coverage and add-direction checks — run in canary mode
#      but pass under every mutant (23 of 248 in round 5).
# Neutering any one of those helpers — `if …; then` → `if true; then` — is a single-line
# edit that touches no fixture and no constant and leaves count and canaries unchanged. So
# is neutering canary()'s own comparison. Round 5's verify did all of these and showed a
# real defect escaping behind each. They are recorded here as the limit, with names: the
# next layer would be a second mutant family for rpc.py and a guard for canary(), and the
# layer after that is the same question again. A suite cannot be immune to someone with
# write access to it; this file stops at saying precisely where that immunity ends.
CANARY_ALWAYS_OK=93
CANARY_ALWAYS_NOTOK=74
CANARY_OFF_BY_ONE=8

canary() {  # canary <label> <mutant-path> <expected fails>
    local label="$1" mutant="$2" want="$3" got
    got=$(EVAL_CHECKS_CANARY="$mutant" EVAL_CHECKS_CANARY_TOKEN="$CANARY_TOKEN" \
          bash "${BASH_SOURCE[0]}" 2>/dev/null | sed -n 's/^CANARY_FAILS=//p' | tail -1)
    if [ "${got:-x}" = "$want" ]; then
        echo "  ok   — canary: against $label, exactly $want assertion(s) fail"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — canary: against $label, ${got:-?} assertion(s) failed, expected $want."
        echo "         Fewer means the suite was WEAKENED (a fixture moved off-boundary, a corpus"
        echo "         hollowed, the assertion helper neutered); more means a fixture was added."
        echo "         If deliberate, update the CANARY_* constant; if not, find what weakened."
        FAIL=$((FAIL + 1))
    fi
}
MUT="$SUITE_TMP/mutants"; mkdir -p "$MUT"
CANARY_TOKEN="$$-$RANDOM-$RANDOM-$(date +%s)"
python3 - "$CHECK" "$MUT" "$CANARY_TOKEN" <<'INNER'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
out = pathlib.Path(sys.argv[2])
# The token line is the FIRST line of every mutant; the child refuses canary mode without it.
src = "# canary-token: %s\n" % sys.argv[3] + src
wrap = """

# -- canary mutant: every check returns ok=%s --
for _k in list(CHECKS):
    CHECKS[_k] = (lambda f: (lambda t, e: dict(f(t, e), ok=%s)))(CHECKS[_k])
"""
# The wrapper must run BEFORE the entry point, not be appended after it — appended, it sat
# below `if __name__ == "__main__": sys.exit(main())` and never executed, and both canaries
# reported zero failures on their first run. A canary that cannot fire is the round-1 shape.
entry = 'if __name__ == "__main__":'
assert src.count(entry) == 1, "mutant builder: entry point not found"
(out / "always_ok.py").write_text(src.replace(entry, wrap % ("True", "True") + "\n" + entry), encoding="utf-8")
(out / "always_notok.py").write_text(src.replace(entry, wrap % ("False", "False") + "\n" + entry), encoding="utf-8")
needle = '"ok": observed <= ceiling,'
assert src.count(needle) == 1, "off-by-one mutant: anchor not found"
(out / "off_by_one.py").write_text(src.replace(needle, '"ok": observed <= ceiling + 1,'), encoding="utf-8")
INNER
# THE MECHANISM MUST NOT SHIP ITS OWN BYPASS. Round 5's verify set EVAL_CHECKS_CANARY in the
# ambient environment, pointing at the real check.py: the suite ran 186 of its assertions,
# printed CANARY_FAILS=0, and exited 0 — the count never evaluated, `make test` green, and
# build-release.sh's new gate satisfied. Canary mode is now entered only with a per-run token
# that the parent writes INTO the mutant file; a stray variable fails loudly instead.
bypass_rc=$(EVAL_CHECKS_CANARY="$CHECK" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; echo $?)
if [ "$bypass_rc" != "0" ]; then
    echo "  ok   — an ambient EVAL_CHECKS_CANARY without the run's token is refused (exit $bypass_rc)"
    PASS=$((PASS + 1))
else
    echo "  FAIL — an ambient EVAL_CHECKS_CANARY switched the suite into canary mode and it exited 0"
    FAIL=$((FAIL + 1))
fi

canary "always-ok"    "$MUT/always_ok.py"    "$CANARY_ALWAYS_OK"
canary "always-notok" "$MUT/always_notok.py" "$CANARY_ALWAYS_NOTOK"
canary "off-by-one"   "$MUT/off_by_one.py"   "$CANARY_OFF_BY_ONE"

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
ECASE="$SUITE_TMP/empty-expect.json"
cat > "$ECASE" <<'JSON'
{"cases":[{"id":"no-expectations","tool":"local_summarize","arguments":{"text":"x"},"expect":{}}]}
JSON
got=$(printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"model\":\"m\",\"text\":\"   \"}"}]}}' \
      | python3 "$RPC" score --case-file "$ECASE" --index 0 --model-requested "" --check "$CHECK" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["checks"]), d["mechanical_ok"])' 2>/dev/null)
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
CCASE="$SUITE_TMP/classify.json"
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

# --- expect_row: assertions about the ROW, not the reply text ---------------------
# Round 2, requirement 6b: `classify-none-of-the-above` exists to test "whether matched:
# false fires when it should", and its only mechanical check was `category_member` — whose
# verdict points BACKWARDS there. The desired outcome (no label named, so matched comes
# back false) FAILS category_member and prints FLAG; the undesired outcome (forcing a
# label onto content that fits neither) PASSES. The one mechanical signal attached to the
# requirement was inverted.
#
# `matched` is a row field, not reply text, so no text check can express it. expect_row is
# the channel: rpc.py compares named payload fields after scoring.
ROWCASE="$SUITE_TMP/expect-row.json"
cat > "$ROWCASE" <<'JSON'
{"cases":[{"id":"row-expect","tool":"local_classify",
  "arguments":{"text":"x","categories":["bug","feature request"]},
  "expect_row":{"matched":false}}]}
JSON
rowcheck() {  # rowcheck <description> <expected mechanical_ok> <payload-json>
    local desc="$1" want="$2" payload="$3" got
    got=$(printf '{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":%s}]}}' \
            "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$payload")" \
          | python3 "$RPC" score --case-file "$ROWCASE" --index 0 --model-requested "" --check "$CHECK" \
          | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["mechanical_ok"]))' 2>/dev/null)
    if [ "$got" = "$want" ]; then echo "  ok   — $desc"; PASS=$((PASS + 1))
    else echo "  FAIL — $desc (mechanical_ok=$got, wanted $want)"; FAIL=$((FAIL + 1)); fi
}
# The DESIRED outcome for out-of-domain content: no label forced, matched false.
rowcheck "an unmatched reply satisfies expect_row {matched:false}" true \
    '{"task":"classify","category":null,"matched":false,"raw_response":"none of these apply"}'
# The UNDESIRED outcome: a label forced onto content that fits neither. It must NOT be green.
rowcheck "a forced label violates expect_row {matched:false}" false \
    '{"task":"classify","category":"bug","matched":true,"raw_response":"bug"}'

# --- rpc.py append: the write itself refuses a symlink, not only the pre-check ---------
# The round-5 mutation batch removed O_NOFOLLOW from the appender and the suite stayed green:
# every end-to-end case was stopped earlier by run.sh's check-then-write refusal, so the flag
# that closes the race window was never exercised. This hits the appender directly, with no
# pre-check in front of it — the only way to see that the OPEN refuses a symlink.
APP_VICTIM="$SUITE_TMP/app-victim-$RANDOM.txt"; printf 'PRECIOUS' > "$APP_VICTIM"
APP_LINK="$SUITE_TMP/app-link-$RANDOM.jsonl"; ln -s "$APP_VICTIM" "$APP_LINK"
printf '{"case":"x"}\n' | python3 "$RPC" append --out "$APP_LINK" >/dev/null 2>&1; rc=$?
if [ "$rc" != "0" ] && [ "$(cat "$APP_VICTIM")" = "PRECIOUS" ]; then
    echo "  ok   — rpc.py append refuses to write through a symlink (O_NOFOLLOW, the write itself)"
    PASS=$((PASS + 1))
else
    echo "  FAIL — rpc.py append followed a symlink: exit $rc, victim now '$(head -c 20 "$APP_VICTIM")'"
    FAIL=$((FAIL + 1))
fi

# A HARD LINK is not a symlink. O_NOFOLLOW says nothing about it, `[ -L ]` is false, and a
# hard link to a regular file IS a regular file — so round 5's `--create` truncated the
# linked victim through every guard. The appender now refuses any path whose link count is
# above one, checked on the open descriptor (fstat), before it truncates.
HL_VICTIM="$SUITE_TMP/hl-victim-$RANDOM.txt"; printf 'PRECIOUS' > "$HL_VICTIM"
HL_LINK="$SUITE_TMP/hl-link-$RANDOM.jsonl"; ln "$HL_VICTIM" "$HL_LINK"
printf '' | python3 "$RPC" append --out "$HL_LINK" --create >/dev/null 2>&1; rc=$?
if [ "$rc" != "0" ] && [ "$(cat "$HL_VICTIM")" = "PRECIOUS" ]; then
    echo "  ok   — rpc.py append --create refuses a hard-linked target and leaves it intact"
    PASS=$((PASS + 1))
else
    echo "  FAIL — rpc.py append --create truncated through a hard link: exit $rc, victim now '$(head -c 20 "$HL_VICTIM")'"
    FAIL=$((FAIL + 1))
fi

# COMPLETENESS IS A SET OF (model, case), NOT A NUMBER. Round 5's `completeness()` compared
# cardinality only: five rows for one case and none for four others was "complete", and a
# byte-identical copy of a case file doubled the run with self-consistent books. The run
# now writes the (model, case) pairs it owes and both the publish gate and the verdict
# compare the multiset.
EXP="$SUITE_TMP/expect-rows-$RANDOM.json"
printf '%s' '[["m","a"],["m","b"],["m","c"],["m","d"],["m","e"]]' > "$EXP"
idrows() {  # idrows <description> <expected exit> <jsonl body>
    local desc="$1" want="$2" body="$3" f rc
    f="$SUITE_TMP/id-$$-$RANDOM.jsonl"; printf '%s' "$body" > "$f"
    python3 "$RPC" complete --out "$f" --expect-rows "$EXP" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$want" ]; then echo "  ok   — $desc"; PASS=$((PASS + 1))
    else echo "  FAIL — $desc (exit $rc, wanted $want)"; FAIL=$((FAIL + 1)); fi
}
idrows "complete: the owed (model, case) pairs, each once" 0 \
'{"case":"a","model_requested":"m","error":null}
{"case":"b","model_requested":"m","error":null}
{"case":"c","model_requested":"m","error":null}
{"case":"d","model_requested":"m","error":null}
{"case":"e","model_requested":"m","error":null}
'
idrows "complete: right COUNT, wrong cases (five rows for one case) is NOT complete" 1 \
'{"case":"a","model_requested":"m","error":null}
{"case":"a","model_requested":"m","error":null}
{"case":"a","model_requested":"m","error":null}
{"case":"a","model_requested":"m","error":null}
{"case":"a","model_requested":"m","error":null}
'
idrows "complete: right cases under the wrong model is NOT complete" 1 \
'{"case":"a","model_requested":"other","error":null}
{"case":"b","model_requested":"other","error":null}
{"case":"c","model_requested":"other","error":null}
{"case":"d","model_requested":"other","error":null}
{"case":"e","model_requested":"other","error":null}
'

# --- rpc.py summarize: the guard that failed, made testable -----------------------
# The guard used to be inline bash counting rows APPENDED, with the comment "a green eval
# that ran no cases is the reporting-without-checking failure in its purest form". A
# recorded tool error is a row, so a run where every single call failed printed
# "5 row(s) written, 0 error(s)" and exited 0 — the harness failing open on precisely the
# state it was written to detect, reproduced against the real binary.
#
# It now lives here as a pure function of the output file, so it can be tested at all.
# THE EXIT-CODE CONTRACT (settled by the maintainer between rounds 2 and 3; 64 added in 4).
#
#   0   the run happened and every mechanical check passed
#   2   the run happened and there are findings — a model did badly, which is DATA
#   1   the run did not happen: nothing measured, a tool/transport/malformed failure, or
#       a row count that is not what the run owed
#   64  usage error, in every program of the harness (round 4 fixed run.sh alone)
#
# Round 2's objection was that a tool error exited 1 while a model returning an empty
# string exited 0 — "the difference is which layer the emptiness happened at, not what it
# means". Three codes make the axis the right one: 1 says the measurement failed, 2 says
# the measurement succeeded and the answer was poor. `make eval` does not report success
# for a run in which every check failed, and does not fail merely because a model is
# imperfect, which it always is.
SUM_OUT=""   # last summarize output, for assertions on WHAT was printed
sumjson() {  # sumjson <description> <expected exit> <expected measured> <jsonl body> [owed]
    local desc="$1" want_rc="$2" want_measured="$3" body="$4" owed="${5:-0}"
    local f out rc measured
    f="$SUITE_TMP/sum-$$-$RANDOM.jsonl"
    printf '%s' "$body" > "$f"
    out=$(python3 "$RPC" summarize --out "$f" --expected "$owed" 2>&1); rc=$?
    SUM_OUT="$out"
    measured=$(printf '%s' "$out" | sed -nE 's/.*measured=([0-9]+).*/\1/p' | head -1)
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
# This fixture is why the exit-code contract had to be written down. It previously
# asserted rc=0 for a run whose second row is an empty reply — round 1 reported that as a
# MEDIUM, and round 2 did not fix it, it PINNED it here as intended behaviour, directly
# under a comment about how "fix the code until the test passes" is the reflex this repo
# keeps punishing. Two clean rows exit 0; a run with findings exits 2.
sumjson "two clean replies exit zero" 0 2 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[{"check":"non_empty","ok":true}],"human_review":["x"]}
{"case":"b","error":null,"mechanical_ok":true,"checks":[{"check":"non_empty","ok":true}],"human_review":["y"]}
'
sumjson "a run where a check failed exits 2, not 0" 2 2 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[{"check":"non_empty","ok":true}],"human_review":["x"]}
{"case":"b","error":null,"mechanical_ok":false,"checks":[{"check":"non_empty","ok":false}],"human_review":["y"]}
'
sumjson "a run where EVERY reply was empty exits 2, never 0" 2 2 \
'{"case":"a","error":null,"mechanical_ok":false,"checks":[{"check":"non_empty","ok":false}],"human_review":[]}
{"case":"b","error":null,"mechanical_ok":false,"checks":[{"check":"non_empty","ok":false}],"human_review":[]}
'
# Measured and errored must be reported separately: "N rows, 0 errors" could not tell a
# run of N real replies from a run of N recorded failures. A partial run is also not a
# green run — exit is non-zero, matching the original `ERRORS -eq 0 || exit 1` intent.
# (This expectation was wrong on first writing: it asserted rc=0. The implementation was
# right and the test was not, so the test moved. Recorded because "fix the code until the
# test passes" is the reflex this repo's history keeps punishing.)
sumjson "a run with a recorded tool error exits 1 — the measurement did not happen" 1 1 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[],"human_review":[]}
{"case":"b","error":"Error: down","mechanical_ok":null,"checks":[]}
'
# --- --expected: the round-4 accounting, which no test passed until now ------------
# Round 4's verify: `--expected` was passed in two places, both in run.sh, and in NO test —
# every sumjson call omitted it, which the code itself documents as "0 disables the check".
# Deleting the shortfall block left the suite at 122/0. The headline structural fix was
# the round-1 shape: asserted, not measured.
sumjson "short of what the run owed, with no error rows, exits 1" 1 4 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[]}
{"case":"b","error":null,"mechanical_ok":true,"checks":[]}
{"case":"c","error":null,"mechanical_ok":true,"checks":[]}
{"case":"d","error":null,"mechanical_ok":true,"checks":[]}
' 5
sumjson "exactly what the run owed, all clean, exits 0" 0 2 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[]}
{"case":"b","error":null,"mechanical_ok":true,"checks":[]}
' 2
# A9: the count is a set equality, not a floor. Six rows against five owed is a duplicated
# model or case file, and round 4 accepted it at exit 0.
sumjson "MORE rows than the run owed exits 1" 1 6 \
'{"case":"a","error":null,"mechanical_ok":true,"checks":[]}
{"case":"b","error":null,"mechanical_ok":true,"checks":[]}
{"case":"c","error":null,"mechanical_ok":true,"checks":[]}
{"case":"d","error":null,"mechanical_ok":true,"checks":[]}
{"case":"e","error":null,"mechanical_ok":true,"checks":[]}
{"case":"f","error":null,"mechanical_ok":true,"checks":[]}
' 5

# A8: ONE definition of complete, exposed as its own subcommand so the publish decision in
# run.sh and the verdict in summarize cannot drift. Round 4 had two: the publish gate said
# "measured>=1 and no errors", summarize said "and total == owed", and `mv` ran before the
# stricter one — so README's "only ever holds a complete run" was overstated.
complete_case() {  # complete_case <description> <expected exit> <jsonl body> <owed>
    local desc="$1" want="$2" body="$3" owed="$4" f rc
    f="$SUITE_TMP/cmp-$$-$RANDOM.jsonl"; printf '%s' "$body" > "$f"
    python3 "$RPC" complete --out "$f" --expected "$owed" >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$want" ]; then echo "  ok   — $desc"; PASS=$((PASS + 1))
    else echo "  FAIL — $desc (exit $rc, wanted $want)"; FAIL=$((FAIL + 1)); fi
}
complete_case "complete: owed rows, all measured" 0 \
'{"case":"a","error":null}
{"case":"b","error":null}
' 2
complete_case "complete: short of owed with no error rows is NOT complete" 1 \
'{"case":"a","error":null}
' 2
complete_case "complete: an error row makes it incomplete" 1 \
'{"case":"a","error":null}
{"case":"b","error":"transport: no response"}
' 2
complete_case "complete: more than owed is not complete either" 1 \
'{"case":"a","error":null}
{"case":"b","error":null}
{"case":"c","error":null}
' 2

# --- A4: server-authored strings cannot forge output lines ------------------------
# Round 3's fix stripped C0 controls EXCEPT tab and newline, so a model id containing "\n"
# still split the flagged-rows table into a forged second line; and it was applied to
# `model` only. Everything the server or the case file authored goes through it now.
# (The fixture is built by python so no escape byte has to appear in this file.)
FORGED_ROW=$(python3 -c 'import json; print(json.dumps({"case":"a","error":None,"mechanical_ok":False,"checks":[{"check":"non_empty","ok":False}],"model":"m\n    forged  [x]  clean\x1b[2K","human_review":[]}))')
sumjson "a model id carrying LF and ESC renders on one line with no escape byte" 2 1 "$FORGED_ROW
" 1
if printf '%s' "$SUM_OUT" | python3 -c 'import sys; sys.exit(0 if "\x1b" in sys.stdin.read() else 1)'; then
    echo "  FAIL — an ESC byte from a server-authored model id reached the terminal"; FAIL=$((FAIL + 1))
elif printf '%s\n' "$SUM_OUT" | grep -q '^    forged'; then
    echo "  FAIL — a newline in a server-authored model id forged a second output line"; FAIL=$((FAIL + 1))
else
    echo "  ok   — LF and ESC in a server-authored string are neutralised before printing"; PASS=$((PASS + 1))
fi
# A11: operator-authored human_review is stripped of controls but never truncated. The one
# declared limit that reaches the operator was 356 characters and was cut mid-sentence.
LONG_ROW=$(python3 -c 'import json; q="LIMIT: " + "the server matched field is substring containment, "*8 + "READ THE TEXT BEFORE BELIEVING THIS FLAG."; print(json.dumps({"case":"a","error":None,"mechanical_ok":True,"checks":[],"human_review":[q]}))')
sumjson "a long human_review line is printed whole" 0 1 "$LONG_ROW
" 1
if printf '%s' "$SUM_OUT" | grep -q 'READ THE TEXT BEFORE BELIEVING THIS FLAG'; then
    echo "  ok   — human_review is not truncated (its last clause reached the terminal)"; PASS=$((PASS + 1))
else
    echo "  FAIL — human_review was truncated; the actionable clause was lost"; FAIL=$((FAIL + 1))
fi

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

# --- run.sh end to end, against a stub binary — hermetic, no oMLX ------------------
# Round 2 reproduced this and it is round 1's headline defect relocated: a TRANSPORT
# failure (timeout, dead server, failed write) writes no row at all, is counted as
# nothing, and `make eval` exits 0. The guard could not see it because it reasons only
# about rows that exist, and had no idea how many cases were attempted.
#
# The stub answers --ping so the preflight passes, then answers the first tools/call and
# goes quiet. Four of five cases vanish. That must not be a successful run.
# NOT under scripts/tests/fixtures/ — that directory means something specific: every file
# in it is a downloader that some version of no-unverified-download.test.sh wrongly
# reported clean, and the scanner enumerates it as "each must be refused". Dropping test
# stubs there made them pass as adversarial samples, which is a true statement about
# nothing and dilutes a set CLAUDE.md says not to prune.
STUB="$REPO/scripts/tests/stubs/stub-mcp.py"
RUNSH="$REPO/scripts/eval/run.sh"
runsh_case() {  # runsh_case <description> <expected exit> <STUB_MODE> <STUB_ANSWER_CALLS>
    local desc="$1" want="$2" mode="$3" answer="$4" out rc
    local dest="$SUITE_TMP/runsh-$RANDOM.jsonl"
    out=$(OMLX_EVAL_BINARY="$STUB" STUB_MODE="$mode" STUB_ANSWER_CALLS="$answer" \
          OMLX_EVAL_TIMEOUT=3 "$RUNSH" --model stub --out "$dest" \
          --cases "$REPO/scripts/eval/cases/summarize.json" 2>&1)
    rc=$?
    if [ "$rc" = "$want" ]; then
        echo "  ok   — $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL — $desc (exit $rc, wanted $want)"
        printf '%s\n' "$out" | tail -6 | sed 's/^/         /'
        FAIL=$((FAIL + 1))
    fi
}
if [ ! -x "$STUB" ]; then
    skip "stub-mcp.py missing — run.sh end-to-end cases cannot run"
else
    runsh_case "a run where 4 of 5 cases time out does NOT exit 0" 1 silent 1
    runsh_case "a run whose server dies mid-way does NOT exit 0"   1 die    1
    # A1: the TOOL-error branch — round 1's entire subject — was unreachable in this suite
    # because the stub only ever produced transport failures. Round 4 shipped `re.sub` one
    # line above `import re` on exactly that branch, so every recorded tool error printed a
    # Python traceback instead of `tool error — …`, and the sanitiser on that path never ran.
    TE_OUT=$(OMLX_EVAL_BINARY="$STUB" STUB_MODE=toolerror STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
             "$RUNSH" --model stub --out "$SUITE_TMP/toolerr-$RANDOM.jsonl" \
             --cases "$REPO/scripts/eval/cases/summarize.json" 2>&1); TE_RC=$?
    if [ "$TE_RC" = "1" ] && printf '%s' "$TE_OUT" | grep -q 'tool error — ' \
       && ! printf '%s' "$TE_OUT" | grep -q 'Traceback'; then
        echo "  ok   — a tool error prints its sanitised line and the run exits 1"; PASS=$((PASS + 1))
    else
        echo "  FAIL — tool-error branch: exit $TE_RC, output: $(printf '%s' "$TE_OUT" | grep -m1 -E 'Traceback|tool error|NameError')"; FAIL=$((FAIL + 1))
    fi
    # A4 (run.sh side): the per-case line prints the server's model id. A stub id carrying
    # OSC/CSI and a newline must not reach the terminal raw. STUB_MODEL is built by python
    # so the escape bytes never appear in this file.
    ESC_OUT=$(OMLX_EVAL_BINARY="$STUB" STUB_MODE=silent STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
              STUB_MODEL="$(python3 -c 'print("m\x1b]0;TITLE\x07\x1b[2K\nforged", end="")')" \
              "$RUNSH" --model stub --out "$SUITE_TMP/esc-$RANDOM.jsonl" \
              --cases "$REPO/scripts/eval/cases/summarize.json" 2>&1)
    if printf '%s' "$ESC_OUT" | python3 -c 'import sys; sys.exit(0 if "\x1b" in sys.stdin.read() else 1)' \
       || printf '%s\n' "$ESC_OUT" | grep -q '^forged'; then
        echo "  FAIL — a server-authored model id reached run.sh's terminal output with escapes/newline"; FAIL=$((FAIL + 1))
    else
        echo "  ok   — run.sh neutralises escapes and newlines in the served model id"; PASS=$((PASS + 1))
    fi

    # The --ping banner is the highest-volume server-authored string in the harness, and
    # round 5's filter stripped C0 only (it also left LF, by necessity — the banner is
    # multi-line). C1 (U+0080–U+009F: 8-bit CSI/OSC) and DEL must not reach the terminal.
    # STUB_PING is built by python so the escape codepoints never appear in this file.
    PING_OUT=$(OMLX_EVAL_BINARY="$STUB" STUB_MODE=silent STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
               STUB_PING="$(python3 -c 'print("stub-mcp: reachable\nloaded: m\x9b[2Kforged\x7f", end="")')" \
               "$RUNSH" --model stub --out "$SUITE_TMP/ping-$RANDOM.jsonl" \
               --cases "$REPO/scripts/eval/cases/summarize.json" 2>&1)
    if printf '%s' "$PING_OUT" | python3 -c 'import sys; t=sys.stdin.read(); sys.exit(0 if ("\x9b" in t or "\x7f" in t) else 1)'; then
        echo "  FAIL — a C1/DEL codepoint from the server's --ping output reached the terminal"; FAIL=$((FAIL + 1))
    else
        echo "  ok   — run.sh strips C1 and DEL from the --ping banner (LF kept: the banner is multi-line)"; PASS=$((PASS + 1))
    fi

    # The stub's fixed reply legitimately fails one case's max_sentences:1, so this run has
    # a finding. That is the point: a fully-answered run exits 2 (findings), never 1
    # (the measurement did not happen). Distinguishing those two is the contract.
    runsh_case "a fully-answered run exits 2 (findings), not 1" 2 silent 99

    # A model whose session never starts must not vanish. Round 3 reproduced a two-model
    # run in which the first model failed `initialize`, and the run published five rows
    # from the second, printed "Every mechanical check passed" and exited 0 — one side of
    # a two-sided comparison, in the file README calls a measurement record, with nothing
    # in it saying a model is missing.
    #
    # The class fix is that run.sh now knows how many rows a run OWES (models × cases).
    # That is the root README already named — "nothing in it says how many rows it should
    # have" — and it closes handshake failure, case-file evaporation and transport failure
    # with one number instead of one branch each.
    MM="$SUITE_TMP/twomodel-$RANDOM.jsonl"
    OMLX_EVAL_BINARY="$STUB" STUB_MODE=nohandshake STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
        STUB_MARKER="$SUITE_TMP/handshake-$RANDOM.marker" \
        "$RUNSH" --model first --model second --out "$MM" \
        --cases "$REPO/scripts/eval/cases/summarize.json" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "1" ]; then
        echo "  ok   — a model whose handshake fails makes the run incomplete, not silent"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — two-model run with a dead first model exited $rc, wanted 1"
        FAIL=$((FAIL + 1))
    fi

    # An unreadable case file must not evaporate either. With the default cases/*.json a
    # malformed classify.json silently dropped exactly the requirements round 3 existed to
    # satisfy, and results.jsonl was overwritten as if complete.
    printf 'not json at all' > "$SUITE_TMP/broken.json"
    OMLX_EVAL_BINARY="$STUB" STUB_MODE=silent STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
        "$RUNSH" --model stub --out "$SUITE_TMP/broken-out.jsonl" \
        --cases "$REPO/scripts/eval/cases/summarize.json" --cases "$SUITE_TMP/broken.json" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "1" ]; then
        echo "  ok   — an unreadable case file aborts rather than silently shrinking the run"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — run with a malformed case file exited $rc, wanted 1"
        FAIL=$((FAIL + 1))
    fi

    # The destination must only ever hold a COMPLETE run. Round 2: an incomplete run wiped
    # results.jsonl, and the file is gitignored so nothing could be recovered — while a
    # truncated JSONL is indistinguishable from a complete one, since no field says how
    # many rows it should have.
    PREV="$SUITE_TMP/prev-$RANDOM.jsonl"
    printf '%s\n' '{"case":"from-a-previous-complete-run","error":null,"mechanical_ok":true,"checks":[]}' > "$PREV"
    OMLX_EVAL_BINARY="$STUB" STUB_MODE=die STUB_ANSWER_CALLS=1 OMLX_EVAL_TIMEOUT=3 \
        "$RUNSH" --model stub --out "$PREV" --cases "$REPO/scripts/eval/cases/summarize.json" >/dev/null 2>&1
    if grep -q 'from-a-previous-complete-run' "$PREV"; then
        echo "  ok   — an incomplete run leaves the previous results intact"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — an incomplete run overwrote the previous complete results"
        FAIL=$((FAIL + 1))
    fi
    if [ -s "$PREV.partial" ]; then
        echo "  ok   — and what it did measure is kept, named .partial"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — the incomplete run's rows were discarded"
        FAIL=$((FAIL + 1))
    fi
    # A7: a leftover .partial must not make the harness single-shot. Round 4 refused to run
    # while one existed, so after any imperfect run — the common case with small models,
    # and the case this harness exists to study — every later `make eval` was blocked.
    # The evidence is kept under a timestamped name and the run proceeds.
    OMLX_EVAL_BINARY="$STUB" STUB_MODE=silent STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
        "$RUNSH" --model stub --out "$PREV" --cases "$REPO/scripts/eval/cases/summarize.json" >/dev/null 2>&1
    rc=$?
    kept=$(ls "$PREV".partial.* 2>/dev/null | head -1)
    if [ "$rc" = "2" ] && [ -n "$kept" ] && grep -q 'meeting-coverage' "$kept"; then
        echo "  ok   — a later run proceeds past a leftover .partial and keeps it under a timestamped name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — leftover .partial: second run exited $rc, kept=${kept:-none}"
        FAIL=$((FAIL + 1))
    fi
    # C2: the staging guards round 4 added had no test — deleting all three was invisible.
    # A symlink planted at <out>.partial must be refused with its target untouched.
    VICTIM="$SUITE_TMP/victim-$RANDOM.txt"; printf 'PRECIOUS' > "$VICTIM"
    SYM_OUT="$SUITE_TMP/symout-$RANDOM.jsonl"; ln -s "$VICTIM" "$SYM_OUT.partial"
    OMLX_EVAL_BINARY="$STUB" STUB_MODE=silent STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
        "$RUNSH" --model stub --out "$SYM_OUT" --cases "$REPO/scripts/eval/cases/summarize.json" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "1" ] && [ "$(cat "$VICTIM")" = "PRECIOUS" ]; then
        echo "  ok   — a symlink at <out>.partial is refused and its target is untouched"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — symlink at .partial: exit $rc, victim now '$(head -c 20 "$VICTIM")'"
        FAIL=$((FAIL + 1))
    fi
    DIR_OUT="$SUITE_TMP/dirout-$RANDOM.jsonl"; mkdir -p "$DIR_OUT.partial"
    OMLX_EVAL_BINARY="$STUB" STUB_MODE=silent STUB_ANSWER_CALLS=99 OMLX_EVAL_TIMEOUT=3 \
        "$RUNSH" --model stub --out "$DIR_OUT" --cases "$REPO/scripts/eval/cases/summarize.json" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "1" ]; then
        echo "  ok   — a directory at <out>.partial is refused"; PASS=$((PASS + 1))
    else
        echo "  FAIL — a directory at <out>.partial: exit $rc"; FAIL=$((FAIL + 1))
    fi
fi

# --- the served model id, through the REAL binary --------------------------------
# Round 2: the call site was untested. Reverting `Self.servedModel(...)` to plain
# `resolvedModel` left all 136 Swift tests green — the decision function was covered, the
# line that uses it was not. Extracting the function did NOT fix that; it only made the
# function testable, and the mutation still survived.
#
# The only thing that can see the call site is the real client parsing a real response. So
# a fake oMLX binds 127.0.0.1 and reports a `model` DIFFERENT from the one requested. If
# the row echoes the request, this goes red.
FAKE="$REPO/scripts/tests/stubs/fake-omlx.py"
BIN="$REPO/.build/debug/OmlxConnectorMCP"
if [ ! -x "$BIN" ]; then
    skip "OmlxConnectorMCP not built — the served-model-id call site cannot be exercised"
elif [ ! -x "$FAKE" ]; then
    skip "fake-omlx.py missing"
else
    python3 "$FAKE" > "$SUITE_TMP/port" 2>/dev/null &
    FAKE_PID=$!
    for _ in $(seq 1 40); do [ -s "$SUITE_TMP/port" ] && break; sleep 0.1; done
    PORT=$(cat "$SUITE_TMP/port" 2>/dev/null)
    if [ -z "$PORT" ]; then
        kill $FAKE_PID 2>/dev/null
        echo "  FAIL — fake oMLX did not start"; FAIL=$((FAIL + 1))
    else
        served=$(OMLX_BASE_URL="http://127.0.0.1:$PORT" OMLX_EVAL_TIMEOUT=20 \
                 "$RUNSH" --model requested-id-not-served --out "$SUITE_TMP/served.jsonl" \
                 --cases "$REPO/scripts/eval/cases/summarize.json" >/dev/null 2>&1;
                 python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(rows[0]["model"] if rows else "NO ROWS")' "$SUITE_TMP/served.jsonl" 2>/dev/null)
        kill $FAKE_PID 2>/dev/null; wait $FAKE_PID 2>/dev/null
        if [ "$served" = "served-id-not-requested" ]; then
            echo "  ok   — the row records the SERVED model id, not the requested one"
            PASS=$((PASS + 1))
        else
            echo "  FAIL — row recorded '$served', expected 'served-id-not-requested'"
            FAIL=$((FAIL + 1))
        fi
    fi
fi

# THE SHIPPED CASE FILES ARE A CALL SITE. Round 3 left it untested: deleting `expect_row`
# from classify-none-of-the-above left the suite byte-identical. Round 4 added a guard that
# read classify.json ONLY, asserted two requirements, and accepted the old `label_is` design
# through an `or` — so deleting `script_purity` from the shipped Chinese case (the one
# requirement issue #1 calls non-negotiable) was still invisible.
#
# So: a MANIFEST. Every shipped case, and every mechanical expectation it must carry. One
# assertion per case, so a failure names the case; and every case in every file must be
# listed, so adding a case is a manifest edit rather than an unguarded addition.
MANIFEST='
summarize.json  meeting-coverage-2sentence     sentence_count no_preamble
summarize.json  traditional-chinese-purity     script_purity sentence_count no_preamble
summarize.json  numbers-one-sentence           sentence_count no_preamble
summarize.json  focus-open-questions           sentence_count no_preamble
summarize.json  short-source-preamble-bait     no_preamble sentence_count
classify.json   classify-negative-hedged       category_member row:category
classify.json   classify-bare-label-discipline category_member row:category
classify.json   classify-none-of-the-above     row:matched
'
while read -r cfile cid needs; do
    [ -n "$cfile" ] || continue
    missing=$(python3 - "$REPO/scripts/eval/cases/$cfile" "$cid" $needs <<'INNER'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
case = next((c for c in doc["cases"] if c["id"] == sys.argv[2]), None)
if case is None:
    print("CASE MISSING"); raise SystemExit
absent = []
for need in sys.argv[3:]:
    if need.startswith("row:"):
        if need[4:] not in (case.get("expect_row") or {}): absent.append(need)
    elif need not in (case.get("expect") or {}):
        absent.append(need)
print(" ".join(absent))
INNER
)
    if [ -z "$missing" ]; then
        echo "  ok   — shipped $cfile/$cid carries: $needs"; PASS=$((PASS + 1))
    else
        echo "  FAIL — shipped $cfile/$cid is missing: $missing"; FAIL=$((FAIL + 1))
    fi
done <<< "$MANIFEST"
unlisted=$(python3 - "$REPO/scripts/eval/cases" <<INNER
import glob, json, os
listed = set()
for line in """$MANIFEST""".splitlines():
    parts = line.split()
    if parts: listed.add((parts[0], parts[1]))
extra = []
for path in sorted(glob.glob(os.path.join("$REPO/scripts/eval/cases", "*.json"))):
    for c in json.load(open(path, encoding="utf-8"))["cases"]:
        if (os.path.basename(path), c["id"]) not in listed:
            extra.append(os.path.basename(path) + "/" + c["id"])
print(",".join(extra))
INNER
)
if [ -z "$unlisted" ]; then
    echo "  ok   — every shipped case is in the manifest (adding one is a manifest edit)"; PASS=$((PASS + 1))
else
    echo "  FAIL — shipped case(s) not in the manifest: $unlisted"; FAIL=$((FAIL + 1))
fi

# ...and expect_row's field names need the guard `expect` already has.
badrow=$(python3 - "$RPC" "$REPO/scripts/eval/cases" <<'INNER'
import glob, importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("rpc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = []
for path in sorted(glob.glob(os.path.join(sys.argv[2], "*.json"))):
    for c in json.load(open(path, encoding="utf-8"))["cases"]:
        for k in (c.get("expect_row") or {}):
            if k not in m.ROW_FIELDS:
                bad.append(f"{os.path.basename(path)}:{c['id']}:{k}")
print(",".join(bad))
INNER
)
if [ -z "$badrow" ]; then
    echo "  ok   — every expect_row field in every case file is a real payload field"
    PASS=$((PASS + 1))
else
    echo "  FAIL — unknown expect_row field(s): $badrow"
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

# THE COUNT, AND WHAT IT IS NOT.
#
# Round 3 found every guard in this file individually deletable with the suite still
# exiting 0. Round 4 answered with EXPECTED_CASES (defined at the top, enforced in the EXIT
# trap) and called it "where the recursion stops". Round 4's verify then showed two ways
# past it without touching it: exit before it runs (fixed — it is in the trap now), and
# WEAKEN instead of delete. `if [ "$actual" = "$expect" ]` → `if true` left this file at
# 122 passed, byte-identical to baseline, because the number counts PASS++ calls, not what
# each call asserted. Moving a boundary fixture back off the boundary, or hollowing a
# 21-entry corpus to one, are the same: the count is invariant under weakening.
#
# So the count catches DELETION, and only that. Weakening is caught by the canary further
# up — the suite re-run against deliberately broken copies of check.py, required to notice
# a pinned number of times. Neither is a claim about a suite that cannot be weakened by
# someone editing both the fixture and the constant; that is a deliberate edit, and no
# self-test distinguishes it from a correct one.
#
# The accounting itself is in finish_suite (EXIT trap). Nothing here — deliberately.
