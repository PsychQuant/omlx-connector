#!/bin/bash
# Tests for plugin/bin/verify-download.sh.
#
# These exist because three consecutive review rounds found fixes shipped with tests
# that could not fail on the defect they were for. The forgery case below is the one
# that matters: it builds the exact binary a reviewer used to defeat the previous
# check, and requires this one to refuse it. Revert verify-download.sh to a
# `codesign -dv | grep TeamIdentifier=` check and that case must go red.
set -u

# The implementation lives in the plugin, because the plugin is what runs on a
# user's machine. scripts/ is repo-only and would not be there.
VERIFY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/plugin/bin/verify-download.sh"
TEAM_ID="6W377FS7BS"
PASS=0
FAIL=0

check() {  # check <description> <expected: pass|refuse> <candidate> <sumfile>
    local desc="$1" expect="$2" file="$3" sum="$4"
    if bash "$VERIFY" "$file" "$sum" "$TEAM_ID" >/dev/null 2>&1; then
        actual=pass
    else
        actual=refuse
    fi
    if [ "$actual" = "$expect" ]; then
        echo "  ok   — $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL — $desc (expected $expect, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify-download-test-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'genuine payload\n' > "$TMP/real"
shasum -a 256 "$TMP/real" > "$TMP/real.sha256"

echo "verify-download.sh"

# --- checksum ---------------------------------------------------------------
printf 'tampered payload\n' > "$TMP/tampered"
check "refuses a payload that does not match the checksum" refuse "$TMP/tampered" "$TMP/real.sha256"

: > "$TMP/empty.sha256"
check "refuses an empty checksum file" refuse "$TMP/real" "$TMP/empty.sha256"
check "refuses a missing checksum file" refuse "$TMP/real" "$TMP/nonexistent.sha256"
check "refuses a missing candidate" refuse "$TMP/nonexistent" "$TMP/real.sha256"

# An HTTP error page saved to disk: correct file, wrong content. This is the case
# `curl` without --fail produced, and it must not survive the checksum.
printf '<html><title>404 Not Found</title></html>\n' > "$TMP/errorpage"
check "refuses an HTTP error page in place of the binary" refuse "$TMP/errorpage" "$TMP/real.sha256"

# --- signature --------------------------------------------------------------
# A real Mach-O is needed for the codesign cases; the built launcher will do.
BUILT=""
for candidate in \
    "$(dirname "$VERIFY")/../../.build/debug/omlx-claude" \
    "$(dirname "$VERIFY")/../../.build/release/omlx-claude"
do
    [ -f "$candidate" ] && { BUILT="$candidate"; break; }
done

if [ -z "$BUILT" ]; then
    echo "  skip — signature cases need a built binary (run: swift build)"
else
    # The forgery. `--identifier` is chosen by whoever signs, so a newline inside it
    # injects a line into `codesign -dv` output. Against the old grep-based check this
    # ad-hoc binary passed; against `codesign -R` it must not.
    cp "$BUILT" "$TMP/forged"
    codesign --force --sign - --identifier "x
TeamIdentifier=$TEAM_ID" "$TMP/forged" 2>/dev/null
    shasum -a 256 "$TMP/forged" > "$TMP/forged.sha256"
    check "refuses an ad-hoc binary that forges TeamIdentifier in codesign output" \
        refuse "$TMP/forged" "$TMP/forged.sha256"

    # Plain ad-hoc, no forgery: also not us.
    cp "$BUILT" "$TMP/adhoc"
    codesign --force --sign - "$TMP/adhoc" 2>/dev/null
    shasum -a 256 "$TMP/adhoc" > "$TMP/adhoc.sha256"
    check "refuses a plainly ad-hoc-signed binary" refuse "$TMP/adhoc" "$TMP/adhoc.sha256"

    # A matching checksum over an unsigned file must still fail on provenance —
    # otherwise the checksum alone would be doing all the work.
    cp "$BUILT" "$TMP/unsigned"
    codesign --remove-signature "$TMP/unsigned" 2>/dev/null
    shasum -a 256 "$TMP/unsigned" > "$TMP/unsigned.sha256"
    check "refuses an unsigned binary even with a correct checksum" \
        refuse "$TMP/unsigned" "$TMP/unsigned.sha256"

    # And the positive case, when the real certificate is available. Without it the
    # suite would only ever prove this script says no.
    if [ -n "${DEVELOPER_ID:-}" ]; then
        cp "$BUILT" "$TMP/signed"
        if codesign --force --options runtime --sign "$DEVELOPER_ID" "$TMP/signed" 2>/dev/null; then
            shasum -a 256 "$TMP/signed" > "$TMP/signed.sha256"
            check "accepts a genuinely Developer ID-signed binary" \
                pass "$TMP/signed" "$TMP/signed.sha256"
        else
            echo "  skip — DEVELOPER_ID set but signing failed"
        fi
    else
        echo "  skip — positive case needs DEVELOPER_ID (set it to run the full suite)"
    fi
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
