#!/bin/bash
# Delegation-quality evaluation harness (issue #1).
#
# WHAT THIS IS: the tests in Tests/ answer "does the code behave as designed" and answer
# it well. They say nothing about whether the delegated work is any GOOD. This drives the
# shipped binary against a live oMLX server over stdio JSON-RPC and records what came back.
#
# WHY IT IS NOT IN `make test`: it needs a model loaded, takes seconds to minutes per
# case, and cannot run in CI. It also lives OUTSIDE both existing globs —
# scripts/tests/*.test.sh and scripts/tests/headed/*.test.sh — so it cannot join either by
# accident. Separation by file layout, not by a flag anyone has to remember (#17's lesson).
#
# WHAT IT DOES NOT CLAIM: nothing here scores coverage or faithfulness, and a green
# mechanical row is not a statement that the model was good. See README.md.
set -u

# Writing to a FIFO whose reader has exited raises SIGPIPE, whose default action is to
# kill the shell outright. That skipped the entire summary — including both guards — and
# left the EXIT trap unrun, so a run that died mid-way looked like a run that produced a
# short file. Ignoring it turns the write into an ordinary failure we can handle.
trap '' PIPE

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINARY="${OMLX_EVAL_BINARY:-$REPO/.build/debug/OmlxConnectorMCP}"
CASE_DIR="$REPO/scripts/eval/cases"
CHECK="$REPO/scripts/eval/check.py"
RPC="$REPO/scripts/eval/rpc.py"
OUT="${OMLX_EVAL_OUT:-$REPO/scripts/eval/results.jsonl}"
TIMEOUT="${OMLX_EVAL_TIMEOUT:-600}"   # a cold model load is minutes, not seconds
MODELS=()
CASE_FILES=()

# `$(( … + TIMEOUT ))` evaluates the CONTENTS of a variable named inside it, so an
# unvalidated OMLX_EVAL_TIMEOUT from the environment reached an arithmetic context and
# could execute arbitrary commands. Demonstrated on macOS /bin/bash 3.2 in the round-1
# verify. Validate before it goes anywhere near `$(( ))`.
case "$TIMEOUT" in
    ''|*[!0-9]*) echo "OMLX_EVAL_TIMEOUT must be a whole number of seconds, got: $TIMEOUT" >&2; exit 2 ;;
esac
[ "$TIMEOUT" -gt 0 ] || { echo "OMLX_EVAL_TIMEOUT must be positive" >&2; exit 2; }

# A missing option value used to die with bash's raw "$2: unbound variable" under set -u,
# while every other argument error here gets a named message.
need() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "$1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
    case "$1" in
        --model)  need "$@"; MODELS+=("$2"); shift 2 ;;
        --cases)  need "$@"; CASE_FILES+=("$2"); shift 2 ;;
        --out)    need "$@"; OUT="$2"; shift 2 ;;
        --help|-h)
            # Renders the comment header only. The old form hard-coded a line range that
            # had drifted past the header and printed four lines of source code, plus a
            # test count ("the 18 tests in Tests/") that was never true.
            sed -n '3,${/^#/!q;p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            echo
            echo "usage: run.sh [--model ID]... [--cases FILE]... [--out PATH]"
            echo "  --model may repeat; omit it to let oMLX serve whatever it has loaded."
            echo "  env: OMLX_BASE_URL (the server; same variable the MCP binary reads),"
            echo "       OMLX_EVAL_BINARY, OMLX_EVAL_TIMEOUT, OMLX_EVAL_OUT"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ ${#CASE_FILES[@]} -gt 0 ] || CASE_FILES=("$CASE_DIR"/*.json)
[ ${#MODELS[@]} -gt 0 ] || MODELS=("")   # "" = no model override; the server decides

# ── Preconditions ─────────────────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
[ -x "$BINARY" ] || {
    echo "not built: $BINARY" >&2
    echo "  run: swift build   (or set OMLX_EVAL_BINARY)" >&2
    exit 1
}

# THE PREFLIGHT IS THE BINARY'S OWN. The first version curled `$OMLX_URL` — which is the
# *usage-1* variable read by omlx-claude, while the binary this harness drives reads
# `OMLX_BASE_URL` (OmlxClient.swift:19). So the go/no-go check verified an address the run
# never used: a live server on one port and a dead one on the other produced a green
# preflight and five tool errors. That is the same shape as the managed-settings defect
# CLAUDE.md describes ("the loopback gate will have verified an address the session does
# not use"), reproduced in a new file.
#
# `--ping` cannot drift from what the run uses, because it IS the run's client: same
# variable, same OmlxConfig.resolveBaseURL, and therefore same LoopbackPolicy. That last
# part also settles the other half — CLAUDE.md forbids "a third path that resolves an
# address without consulting the policy", and a bash reimplementation here would have been
# a fourth.
if ! PING=$("$BINARY" --ping 2>&1); then
    echo "oMLX preflight failed — nothing to evaluate" >&2
    printf '%s\n' "$PING" | sed 's/^/  /' >&2
    echo "  start oMLX, or set OMLX_BASE_URL to where it listens" >&2
    exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/omlx-eval.XXXXXX")
SERVER_PID=""
STAGING="${OUT}.partial"
: > "$STAGING"
cleanup() {
    # NOT `exec 3>&- 2>/dev/null` — that form applies both redirections to the shell and
    # is exactly what server_stop below documents as harmful. It survived here for a whole
    # round because the fix was applied to the line a reviewer named.
    exec 3>&-
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP"
    # STAGING lives beside $OUT, not in $TMP, so an interrupted or failed run leaves the
    # rows it did measure on disk under a name that says what they are. Round 2: staging
    # inside $TMP meant the cleanup trap destroyed every measured row on interrupt, and
    # the mv failure branch destroyed the very rows it had failed to publish.
    if [ -s "$STAGING" ]; then
        echo "  partial results kept at: $STAGING" >&2
    else
        rm -f "$STAGING" 2>/dev/null
    fi
}
trap cleanup EXIT

# ── JSON-RPC over stdio ───────────────────────────────────────────────────────────
# THE NON-OBVIOUS PART: stdin must stay open until the reply arrives. The first probe
# written for this closed it right after writing the request; the server exited without
# answering, which looks exactly like a broken server rather than a closed pipe.
#
# `exec 3>"$FIFO"` holds it open — the fd outlives each write. macOS ships bash 3.2, which
# has no `coproc`, and an explicit fd on a FIFO states the mechanism more plainly anyway.
RPC_ID=0
LINES_READ=0
RESPONSE=""

server_start() {
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
    # `exec 3>&- 2>/dev/null` applies BOTH redirections to the current shell, permanently:
    # the first model's iteration silently closed run.sh's stderr for the rest of the run,
    # discarding every diagnostic after it. Close fd 3 and nothing else.
    exec 3>&-
    if [ -n "$SERVER_PID" ]; then
        # Do NOT wait unboundedly. A server that has stopped reading stdin — hung, wedged
        # mid-request, or asleep — never sees the EOF from closing fd 3, and `wait` then
        # blocks forever. Found by the stub-binary test in the hermetic suite, which hung
        # the whole of `make test` until this kill was added: the failure mode is a harness
        # that never returns, which is worse than one that reports wrongly.
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=""
    fi
}

server_alive() { [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; }

rpc_send() {
    # Check before writing, not after. rpc_await's dead-server check came too late: the
    # next write to the orphaned FIFO happened first.
    server_alive || { echo "server is gone; not sending" >&2; return 1; }
    printf '%s\n' "$1" >&3 || { echo "write to server failed" >&2; return 1; }
}

# Sets $RESPONSE. Deliberately NOT called through $( ) — command substitution runs in a
# subshell, so LINES_READ's increments never reached the parent and every await re-read
# the whole file from line 1. The cursor is documented as cross-call state; now it is.
rpc_await() {
    local want="$1" deadline=$(( $(date +%s) + TIMEOUT )) total line hit
    RESPONSE=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        total=$(wc -l < "$TMP/stdout" | tr -d ' ')
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
            [ -n "$hit" ] && { RESPONSE="$hit"; return 0; }
        done
        server_alive || { echo "server exited: $(tail -3 "$TMP/stderr")" >&2; return 1; }
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
  "clientInfo":{"name":"omlx-eval","version":"1"}}}))' "$RPC_ID")" || return 1
    rpc_await "$RPC_ID" || return 1
    rpc_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}

# ── Run ───────────────────────────────────────────────────────────────────────────
echo "eval → $OUT"
echo "  binary: $BINARY"
printf '%s\n' "$PING" | sed 's/^/  /'

for model in "${MODELS[@]}"; do
    echo
    echo "model: ${model:-(server default)}"
    server_start
    if ! handshake; then
        echo "  handshake failed — skipping this model" >&2
        server_stop
        continue
    fi

    for case_file in "${CASE_FILES[@]}"; do
        [ -f "$case_file" ] || { echo "  no such case file: $case_file" >&2; continue; }
        # A malformed or empty case file used to be skipped in silence: python failed,
        # `count` was empty, and `[ "$idx" -lt "" ]` quietly evaluated false.
        if ! count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cases"]))' "$case_file" 2>&1); then
            echo "  unreadable case file $case_file: $count" >&2
            continue
        fi
        [ "$count" -gt 0 ] || { echo "  case file has no cases: $case_file" >&2; continue; }
        idx=0
        while [ "$idx" -lt "$count" ]; do
            RPC_ID=$((RPC_ID + 1))
            request=$(python3 "$RPC" request \
                          --case-file "$case_file" --index "$idx" --id "$RPC_ID" --model "$model")
            case_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][int(sys.argv[2])]["id"])' "$case_file" "$idx")
            case_tool=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cases"][int(sys.argv[2])]["tool"])' "$case_file" "$idx")
            printf '  %-28s ' "$case_id"

            if ! rpc_send "$request" || ! rpc_await "$RPC_ID"; then
                echo "ERROR (no response)"
                # WRITE A ROW. Round 1 found the guard failing open when every call
                # returned a tool error; round 2 found the same failure one layer out,
                # because a TRANSPORT failure produced no row at all and the verdict
                # reasons only about rows that exist. Four of five cases could vanish and
                # `make eval` still exited 0. An error row is how the verdict learns.
                python3 -c '
import json, sys
print(json.dumps({"case": sys.argv[1], "tool": sys.argv[2], "model_requested": sys.argv[3] or None,
                  "model": None, "elapsed_seconds": None, "finish_reason": None,
                  "text": None, "checks": [], "mechanical_ok": None,
                  "human_review": [], "error": "transport: no response from the server"},
                 ensure_ascii=False))' "$case_id" "$case_tool" "$model" >> "$STAGING"
                idx=$((idx + 1))
                server_alive || break
                continue
            fi

            if ! row=$(printf '%s' "$RESPONSE" | python3 "$RPC" score \
                           --case-file "$case_file" --index "$idx" \
                           --model-requested "$model" --check "$CHECK"); then
                echo "ERROR (scoring failed)"
                python3 -c '
import json, sys
print(json.dumps({"case": sys.argv[1], "tool": sys.argv[2], "model_requested": sys.argv[3] or None,
                  "model": None, "elapsed_seconds": None, "finish_reason": None,
                  "text": None, "checks": [], "mechanical_ok": None,
                  "human_review": [], "error": "scoring failed"},
                 ensure_ascii=False))' "$case_id" "$case_tool" "$model" >> "$STAGING"
                idx=$((idx + 1))
                continue
            fi
            # A failed append used to leave the row counter incremented anyway, so the
            # guard counted attempts rather than writes.
            printf '%s\n' "$row" >> "$STAGING" || { echo "ERROR (could not write row)"; exit 1; }
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
        server_alive || break
    done
    server_stop
done

# Publish atomically. The first version truncated the destination BEFORE the first model
# ran, so a run that died part-way had already destroyed the previous results — and the
# survivor was indistinguishable from a complete single-model file, because nothing in it
# says how many rows it should have. Staging plus a rename means the destination is only
# ever replaced by a run that reached this line.
# THE DESTINATION ONLY EVER HOLDS A COMPLETE RUN.
#
# Round 2: a run that measured nothing still wiped results.jsonl, destroying the previous
# run's evidence — and the file is gitignored, so there was nothing to fall back to. The
# first fix (publish when staging is non-empty) stopped working the moment transport
# failures started writing error rows: staging was non-empty again, and a five-row file of
# which four are errors would have replaced a complete one.
#
# So the gate is what the file will MEAN, not whether it has bytes: at least one measured
# reply and no failures. Anything else stays under `.partial`, named for what it is, and
# $OUT keeps the last complete run. This is the property the README claims when it calls
# the file a measurement record — a silently truncated record is worse than none, and
# nothing inside it says how many rows it should have had.
INCOMPLETE=$(python3 - "$STAGING" <<'PYEOF'
import json, sys
measured = errored = 0
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            errored += 1
            continue
        errored += 1 if row.get("error") else 0
        measured += 0 if row.get("error") else 1
except OSError:
    print("no output file")
    raise SystemExit
if measured == 0:
    print("nothing was measured")
elif errored:
    print(f"{errored} of {measured + errored} call(s) failed")
PYEOF
)
if [ -n "$INCOMPLETE" ]; then
    echo >&2
    echo "  incomplete run ($INCOMPLETE) — $OUT left as it was." >&2
    echo "  What this run did produce: $STAGING" >&2
    python3 "$RPC" summarize --out "$STAGING"
    exit 1
fi
mv "$STAGING" "$OUT" || { echo "could not publish to $OUT; rows kept at $STAGING" >&2; exit 1; }

echo
python3 "$RPC" summarize --out "$OUT"
RC=$?
echo "  rows: $OUT"
exit $RC
