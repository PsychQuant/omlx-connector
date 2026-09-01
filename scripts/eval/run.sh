#!/bin/bash
# Delegation-quality evaluation harness (issue #1).
#
# WHAT THIS IS: the 18 tests in Tests/ all use StubClient — not one sends anything to a
# real model. They answer "does the code behave as designed" and answer it well. They
# say nothing about whether the delegated work is any GOOD. This drives the shipped
# binary against a live oMLX server and records what came back.
#
# WHY IT IS NOT IN `make test`: it needs a model loaded, takes seconds to minutes per
# case, and cannot run in CI. Folding it into a fast hermetic suite is how suites stop
# being run. It also lives OUTSIDE both existing globs — scripts/tests/*.test.sh and
# scripts/tests/headed/*.test.sh — so it cannot join either by accident. Separation by
# file layout, not by a flag anyone has to remember (the #17 lesson).
#
# WHAT IT DOES NOT CLAIM: nothing here scores coverage or faithfulness. Those are
# presented for a human to read. See README.md in this directory.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINARY="${OMLX_EVAL_BINARY:-$REPO/.build/debug/OmlxConnectorMCP}"
CASE_DIR="$REPO/scripts/eval/cases"
CHECK="$REPO/scripts/eval/check.py"
OMLX_URL="${OMLX_URL:-http://127.0.0.1:8000}"
OUT="${OMLX_EVAL_OUT:-$REPO/scripts/eval/results.jsonl}"
TIMEOUT="${OMLX_EVAL_TIMEOUT:-600}"   # a cold model load is minutes, not seconds
MODELS=()
CASE_FILES=()

while [ $# -gt 0 ]; do
    case "$1" in
        --model)  MODELS+=("$2"); shift 2 ;;
        --cases)  CASE_FILES+=("$2"); shift 2 ;;
        --out)    OUT="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            echo
            echo "usage: run.sh [--model ID]... [--cases FILE]... [--out PATH]"
            echo "  --model may repeat; omit it to let oMLX serve whatever it has loaded."
            echo "  env: OMLX_URL, OMLX_EVAL_BINARY, OMLX_EVAL_TIMEOUT, OMLX_EVAL_OUT"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ ${#CASE_FILES[@]} -gt 0 ] || CASE_FILES=("$CASE_DIR"/*.json)
[ ${#MODELS[@]} -gt 0 ] || MODELS=("")   # "" = no model override; the server decides

# ── Preconditions. Each aborts: an eval that quietly ran zero cases and exited 0 is
# the exact "reporting without checking" failure this harness exists to avoid. ──────
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
[ -x "$BINARY" ] || {
    echo "not built: $BINARY" >&2
    echo "  run: swift build   (or set OMLX_EVAL_BINARY)" >&2
    exit 1
}
curl -s -m 5 "$OMLX_URL/v1/models" >/dev/null 2>&1 || {
    echo "no oMLX server at $OMLX_URL — nothing to evaluate" >&2
    echo "  start oMLX, or set OMLX_URL" >&2
    exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/omlx-eval.XXXXXX")
SERVER_PID=""
cleanup() {
    exec 3>&- 2>/dev/null
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# ── JSON-RPC over stdio ───────────────────────────────────────────────────────────
# THE NON-OBVIOUS PART: stdin must stay open until the reply arrives. The first probe
# written for this closed it right after writing the request; the server exited without
# answering, which looks exactly like a broken server rather than a closed pipe.
#
# `exec 3>"$FIFO"` is what holds it open — the fd outlives each write. macOS ships bash
# 3.2, which has no `coproc`, and a FIFO plus an explicit fd states the mechanism more
# plainly than a coprocess would anyway.
RPC_ID=0
LINES_READ=0

server_start() {   # server_start
    local fifo="$TMP/stdin"
    rm -f "$fifo" "$TMP/stdout" "$TMP/stderr"
    mkfifo "$fifo"
    : > "$TMP/stdout"
    "$BINARY" < "$fifo" > "$TMP/stdout" 2> "$TMP/stderr" &
    SERVER_PID=$!
    exec 3> "$fifo"
    LINES_READ=0
}

server_stop() {
    exec 3>&- 2>/dev/null
    if [ -n "$SERVER_PID" ]; then
        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=""
    fi
}

rpc_send() { printf '%s\n' "$1" >&3; }

# rpc_await <id> — echoes the matching response object, or returns 1 on timeout.
# Responses are newline-delimited JSON; anything without our id (notifications, log
# lines) is skipped rather than mistaken for the answer.
rpc_await() {
    local want="$1" deadline=$(( $(date +%s) + TIMEOUT )) total line hit
    while [ "$(date +%s)" -lt "$deadline" ]; do
        total=$(wc -l < "$TMP/stdout" | tr -d ' ')
        if [ "$total" -gt "$LINES_READ" ]; then
            while [ "$LINES_READ" -lt "$total" ]; do
                LINES_READ=$((LINES_READ + 1))
                line=$(sed -n "${LINES_READ}p" "$TMP/stdout")
                hit=$(printf '%s' "$line" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("id") == int(sys.argv[1]) else 1)
' "$want" 2>/dev/null && printf '%s' "$line")
                [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
            done
        fi
        # The server is gone and nothing matched: report it rather than spinning out
        # the full timeout on a process that already exited.
        kill -0 "$SERVER_PID" 2>/dev/null || { echo "server exited: $(tail -3 "$TMP/stderr")" >&2; return 1; }
        sleep 0.2
    done
    echo "timed out after ${TIMEOUT}s waiting for response id=$want" >&2
    return 1
}

handshake() {
    RPC_ID=$((RPC_ID + 1))
    rpc_send "$(python3 -c '
import json,sys
print(json.dumps({"jsonrpc":"2.0","id":int(sys.argv[1]),"method":"initialize","params":{
  "protocolVersion":"2024-11-05","capabilities":{},
  "clientInfo":{"name":"omlx-eval","version":"1"}}}))' "$RPC_ID")"
    rpc_await "$RPC_ID" >/dev/null || return 1
    rpc_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}

# ── Run ───────────────────────────────────────────────────────────────────────────
: > "$OUT"
ROWS=0
ERRORS=0
echo "eval → $OUT"
echo "  binary: $BINARY"
echo "  server: $OMLX_URL"

for model in "${MODELS[@]}"; do
    echo
    echo "model: ${model:-(server default)}"
    server_start
    if ! handshake; then
        echo "  handshake failed — skipping this model" >&2
        ERRORS=$((ERRORS + 1))
        server_stop
        continue
    fi

    for case_file in "${CASE_FILES[@]}"; do
        [ -f "$case_file" ] || { echo "  no such case file: $case_file" >&2; ERRORS=$((ERRORS+1)); continue; }
        count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cases"]))' "$case_file")
        idx=0
        while [ "$idx" -lt "$count" ]; do
            RPC_ID=$((RPC_ID + 1))
            request=$(python3 "$REPO/scripts/eval/rpc.py" request \
                          --case-file "$case_file" --index "$idx" --id "$RPC_ID" --model "$model")
            case_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][int(sys.argv[2])]["id"])' "$case_file" "$idx")
            printf '  %-28s ' "$case_id"

            rpc_send "$request"
            if ! response=$(rpc_await "$RPC_ID"); then
                echo "ERROR (no response)"
                ERRORS=$((ERRORS + 1))
                idx=$((idx + 1))
                continue
            fi

            row=$(printf '%s' "$response" | python3 "$REPO/scripts/eval/rpc.py" score \
                      --case-file "$case_file" --index "$idx" \
                      --model-requested "$model" --check "$CHECK")
            rc=$?
            if [ $rc -ne 0 ]; then
                echo "ERROR (scoring failed)"
                ERRORS=$((ERRORS + 1))
                idx=$((idx + 1))
                continue
            fi
            printf '%s\n' "$row" >> "$OUT"
            ROWS=$((ROWS + 1))
            printf '%s\n' "$row" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("error"):
    print("tool error — " + d["error"][:60]); raise SystemExit
bad = [c["check"] for c in d["checks"] if not c["ok"]]
mark = "ok  " if not bad else "FLAG"
extra = "" if not bad else "  " + ",".join(bad)
fin = "" if not d.get("finish_reason") else "  [%s]" % d["finish_reason"]
print("%s  %5.1fs  %s%s%s" % (mark, d.get("elapsed_seconds") or 0.0, d.get("model") or "?", fin, extra))'
            idx=$((idx + 1))
        done
    done
    server_stop
done

echo
echo "  $ROWS row(s) written, $ERRORS error(s)"
# Zero rows means the harness measured nothing. That must not exit 0 — a green eval
# that ran no cases is the reporting-without-checking failure in its purest form.
[ "$ROWS" -gt 0 ] || { echo "  no rows produced — nothing was evaluated" >&2; exit 1; }
echo "  read them: python3 -m json.tool < $OUT   (or: jq . $OUT)"
echo "  FLAG marks a mechanical check that failed. Coverage and faithfulness are NOT"
echo "  scored — read the 'text' field and judge those yourself."
[ "$ERRORS" -eq 0 ] || exit 1
