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
SKIP=0

# A skipped case used to exit 0 like a passing one, which hid the single most important
# assertion in this file: the positive case is what caught a requirement string that
# refused EVERYTHING while satisfying all eight negative cases. In CI, where
# DEVELOPER_ID is unset, that guard was silently absent and a "refuses everything"
# regression would have shipped green.
#
# Skips are now counted and reported, and REQUIRE_FULL_SUITE=1 turns any skip into a
# failure — which is what a release path should set.
skip() { echo "  SKIP — $1"; SKIP=$((SKIP + 1)); }

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
    skip "signature cases need a built binary (run: swift build)"
else
    # The forgery. `--identifier` is chosen by whoever signs, so a newline inside it
    # injects a line into `codesign -dv` output. Against the old grep-based check this
    # ad-hoc binary passed; against `codesign -R` it must not.
    # Constructing the forgery is itself an assertion. Previously codesign's exit status
    # was discarded, so if it ever refused the embedded newline the file would simply be
    # *unsigned*, verify-download.sh would refuse it for that instead, and this case
    # would print `ok` forever while defending nothing.
    cp "$BUILT" "$TMP/forged"
    if ! codesign --force --sign - --identifier "x
TeamIdentifier=$TEAM_ID" "$TMP/forged" 2>/dev/null; then
        echo "  FAIL — could not construct the forgery; this case is no longer meaningful"
        FAIL=$((FAIL + 1))
    elif ! codesign -dv "$TMP/forged" 2>&1 | grep -qx "TeamIdentifier=$TEAM_ID"; then
        echo "  FAIL — the forgery does not inject the line it exists to inject"
        FAIL=$((FAIL + 1))
    else
        shasum -a 256 "$TMP/forged" > "$TMP/forged.sha256"
        check "refuses an ad-hoc binary that forges TeamIdentifier in codesign output" \
            refuse "$TMP/forged" "$TMP/forged.sha256"
    fi

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
    # An Apple Development certificate from the SAME team must be refused. Round 6
    # reproduced it passing: subject.OU is the team id on both certificate kinds, so an
    # OU-only requirement cannot tell a dev cert from a Developer ID one. This case is the
    # reason the requirement now names the Developer ID marker OID — without it, anyone
    # holding any team member's development certificate satisfies the gate.
    #
    # Constructing the fixture is part of the assertion: if signing fails the binary is
    # merely unsigned, would be refused for that instead, and this case would report `ok`
    # while defending nothing.
    APPLE_DEV=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -i "Apple Development" | head -1 | awk '{print $2}')
    if [ -n "$APPLE_DEV" ] && [ -n "$BUILT" ]; then
        cp "$BUILT" "$TMP/appledev"
        if ! codesign --force --options runtime --sign "$APPLE_DEV" "$TMP/appledev" 2>/dev/null; then
            echo "  FAIL — could not sign with Apple Development; this case proves nothing"
            FAIL=$((FAIL + 1))
        elif ! codesign -dv --verbose=4 "$TMP/appledev" 2>&1 | grep -q "Authority=Apple Development"; then
            echo "  FAIL — fixture is not actually Apple Development-signed"
            FAIL=$((FAIL + 1))
        else
            shasum -a 256 "$TMP/appledev" > "$TMP/appledev.sha256"
            check "refuses an Apple Development cert from the same team" \
                refuse "$TMP/appledev" "$TMP/appledev.sha256"
        fi
    else
        skip "Apple Development case needs an Apple Development identity in the keychain"
    fi

    if [ -n "${DEVELOPER_ID:-}" ]; then
        cp "$BUILT" "$TMP/signed"
        if codesign --force --options runtime --sign "$DEVELOPER_ID" "$TMP/signed" 2>/dev/null; then
            shasum -a 256 "$TMP/signed" > "$TMP/signed.sha256"
            check "accepts a genuinely Developer ID-signed binary" \
                pass "$TMP/signed" "$TMP/signed.sha256"
        else
            skip "DEVELOPER_ID set but signing failed"
        fi
    else
        skip "positive case needs DEVELOPER_ID — the 'refuses everything' guard did NOT run"
    fi
fi

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"

if [ "$SKIP" -gt 0 ] && [ "${REQUIRE_FULL_SUITE:-}" = "1" ]; then
    echo "  REQUIRE_FULL_SUITE=1 and $SKIP case(s) did not run — treating as failure." >&2
    exit 1
fi
if [ "$SKIP" -gt 0 ]; then
    echo "  note: $SKIP case(s) did not run. Set DEVELOPER_ID to run them all," >&2
    echo "        and REQUIRE_FULL_SUITE=1 to make a skip fail." >&2
fi
[ "$FAIL" -eq 0 ]
