#!/bin/bash
# Headed tests for omlx-claude — the interactive path, driven through a real PTY.
#
# WHY THIS LIVES IN A SUBDIRECTORY: `make test-shell` globs `scripts/tests/*.test.sh`,
# which is NOT recursive, so nothing here joins the hermetic suite. That is the whole
# mechanism keeping `make test` free of a live-server dependency — it is file layout,
# not a flag anyone has to remember. If someone ever makes that glob recursive, this
# suite silently joins `make test` and it starts needing oMLX. See the comment on the
# glob in the Makefile.
#
# WHAT IT ACTUALLY COVERS: oMLX renders a *different interface* depending on isatty.
# Through a PTY it draws a curses picker with an "↑↓ navigate … q cancel" footer;
# without one it prints a plain numbered list and no footer. `-p` can never reach the
# first. That branch is the reason the headed/headless rule exists — see
# .claude/rules/headed-and-headless-testing.md.
#
# THE ASSERTION THAT MATTERS is CASE 2. A headed test's characteristic failure is
# asserting on output that would have appeared anyway, so it passes while driving
# nothing. Case 2 is keystroke-DEPENDENT: send `q`, require the session to end. No
# injection, no exit, red. Prove it by running with HEADED_NO_INJECT=1 — case 2 must
# fail. That switch exists to be exercised, not to be believed.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BINARY="$REPO/.build/debug/omlx-claude"
OMLX_URL="${OMLX_URL:-http://127.0.0.1:8000}"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  ok   — $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }
# A skip is not a pass. Counted and printed; REQUIRE_FULL_SUITE=1 turns any into a
# failure, which is what a release path should set. This repo has already been bitten
# once by a silently-skipped case that was the only guard against a check that refused
# everything — see scripts/tests/verify-download.test.sh.
skip() { echo "  SKIP — $1"; SKIP=$((SKIP + 1)); }

echo "headed/model-picker"

# ── Preconditions. Each is a skip, never a silent pass. ────────────────────────────
command -v tmux >/dev/null 2>&1 || {
    skip "tmux not installed (brew install tmux) — headed path cannot be driven"
    echo; echo "  $PASS passed, $FAIL failed, $SKIP skipped"
    [ -n "${REQUIRE_FULL_SUITE:-}" ] && { echo "  REQUIRE_FULL_SUITE set — a skip is a failure"; exit 1; }
    exit 0
}
[ -x "$BINARY" ] || {
    skip "omlx-claude not built (run: swift build --product omlx-claude)"
    echo; echo "  $PASS passed, $FAIL failed, $SKIP skipped"
    [ -n "${REQUIRE_FULL_SUITE:-}" ] && exit 1
    exit 0
}
curl -s -m 5 "$OMLX_URL/v1/models" >/dev/null 2>&1 || {
    skip "no oMLX server at $OMLX_URL — the picker has nothing to list"
    echo; echo "  $PASS passed, $FAIL failed, $SKIP skipped"
    [ -n "${REQUIRE_FULL_SUITE:-}" ] && exit 1
    exit 0
}

# ── Isolation is mandatory, not hygiene. ──────────────────────────────────────────
# This drives the exact code path that writes to the operator's real configuration,
# which is the defect #12 is about. Running it unisolated would reproduce that defect
# on the machine running the test. CLAUDE_CONFIG_DIR survives the whole
# omlx-claude → omlx launch claude → Claude Code exec chain (verified in #12).
PROBE=$(mktemp -d "${TMPDIR:-/tmp}/omlx-headed-cfg.XXXXXX")
SESSION="omlx-headed-$$"
REAL_STATE="$HOME/.claude.json"
BEFORE=""
[ -f "$REAL_STATE" ] && BEFORE=$(shasum -a 256 "$REAL_STATE" | awk '{print $1}')

cleanup() {
    tmux kill-session -t "$SESSION" 2>/dev/null
    rm -rf "$PROBE"
}
trap cleanup EXIT

tmux new-session -d -s "$SESSION" -x 200 -y 50 -c "${TMPDIR:-/tmp}" \
    "CLAUDE_CONFIG_DIR=$PROBE $BINARY" 2>/dev/null || {
    fail "could not start a tmux session"
    echo; echo "  $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
}

# Poll for the picker rather than sleeping a fixed amount: listing models is a network
# round-trip whose latency is not ours to predict. A timeout here is a FAILURE, not a
# skip — "we waited and nothing came" is a real result, and downgrading it to a skip
# would make the suite decorative exactly when something is broken.
PICKER_FOOTER='navigate'
appeared=""
for _ in $(seq 1 40); do
    if tmux capture-pane -p -t "$SESSION" 2>/dev/null | grep -q "$PICKER_FOOTER"; then
        appeared="yes"; break
    fi
    sleep 0.5
done

# ── CASE 1: the TTY-only branch was reached ───────────────────────────────────────
# The footer string exists only in the curses picker. The non-TTY fallback prints a
# numbered list and no footer, so this cannot pass on the headless path.
if [ -n "$appeared" ]; then
    pass "curses picker rendered (TTY-only branch reached)"
else
    fail "picker footer '$PICKER_FOOTER' never appeared within 20s"
    echo "       last pane:"
    tmux capture-pane -p -t "$SESSION" 2>/dev/null | grep -v '^$' | tail -5 | sed 's/^/         /'
fi

# ── CASE 2: keystrokes actually reach the process ─────────────────────────────────
# The load-bearing case. `q` cancels the picker, so the session ends. If injection is
# a no-op the picker stays up and the session survives — which is precisely what
# HEADED_NO_INJECT=1 simulates.
if [ -n "$appeared" ]; then
    if [ -n "${HEADED_NO_INJECT:-}" ]; then
        echo "       (HEADED_NO_INJECT set — deliberately sending nothing)"
    else
        tmux send-keys -t "$SESSION" q
    fi

    ended=""
    for _ in $(seq 1 20); do
        tmux has-session -t "$SESSION" 2>/dev/null || { ended="yes"; break; }
        sleep 0.5
    done

    if [ -n "$ended" ]; then
        pass "injected 'q' cancelled the picker and the session ended"
    else
        fail "session still alive 10s after 'q' — keystrokes are not reaching the process"
    fi
else
    skip "injection case needs the picker, which never appeared"
fi

# ── Isolation: enforced here, but NOT asserted here. Say so rather than fake it. ──
# CLAUDE_CONFIG_DIR is set for every session this suite starts — mandatory per the
# rule, because a headed test runs the exact code path that writes to the operator's
# real configuration.
#
# Asserting that it *worked* does not belong in this test, and two wrong versions were
# written before that became clear. Both are recorded because each is a distinct trap:
#
#   1. "hash ~/.claude.json, require unchanged" — UNSOUND. That file is written by any
#      live Claude Code session, including the one running this test, so a change is
#      not attributable to the subject. It passed on one run and failed on the next
#      with identical code.
#   2. "require the isolated root to be populated" — WRONG FOR THIS TEST. Cancelling at
#      the picker means Claude Code never launches, so nothing writes anywhere. An
#      empty directory is correct behaviour here, not a leak.
#
# Attributable isolation evidence needs a run that actually launches, which costs a
# model load and belongs in a separate, slower case. State is reported as a note so a
# human still sees it, and not counted — an uncounted truth beats a green assertion
# that proves nothing.
probe_state=$(ls -A "$PROBE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
echo "       note: isolated CLAUDE_CONFIG_DIR holds: ${probe_state:-(empty — expected; the picker was cancelled before launch)}"
if [ -f "$REAL_STATE" ]; then
    AFTER=$(shasum -a 256 "$REAL_STATE" | awk '{print $1}')
    [ "$BEFORE" = "$AFTER" ] \
        && echo "       note: ~/.claude.json unchanged during this run" \
        || echo "       note: ~/.claude.json changed during this run — expected while another Claude Code session is live; not attributable to the subject"
fi

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$SKIP" -gt 0 ] && [ -n "${REQUIRE_FULL_SUITE:-}" ]; then
    echo "  REQUIRE_FULL_SUITE set — a skip is a failure"
    exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
