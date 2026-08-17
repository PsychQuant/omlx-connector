#!/bin/bash
# Asserts a property, not a file: nothing in plugin/ installs or executes a downloaded
# binary without going through the shared verification.
#
# Round 2 rated an unverified download CRITICAL. Round 3 found the fix had been applied
# to plugin/hooks/session-start.sh and not to plugin/bin/omlx-connector-wrapper.sh —
# same plugin, same release, other binary, still `curl -sL` into `chmod +x` into `exec`.
# A per-file test would have been green for that, because the file it named was fixed.
#
# So this scans every shipped script. Add a third downloader that skips the verifier and
# this goes red without anyone having to remember to add a case for it.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Strip comments and blank lines before scanning. These files necessarily *describe*
# the defect they no longer have — "this used to be `curl -sL` with no --fail" — and a
# scanner that reads prose would flag the explanation as the offence.
code_of() { grep -vE '^\s*(#|$)' "$1"; }
PLUGIN="$ROOT/plugin"
VERIFIER="verify-download.sh"
FETCHER="fetch-release-binary.sh"
PASS=0
FAIL=0

ok()   { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

echo "no unverified downloads in plugin/"

# Every script that fetches from the network must either BE the fetcher, or delegate to
# it. Nothing may hand-roll the download.
while IFS= read -r script; do
    rel="${script#$ROOT/}"
    base=$(basename "$script")
    code_of "$script" | grep -q 'curl' || continue   # not a downloader, nothing to check

    if [ "$base" = "$FETCHER" ]; then
        # The one place allowed to download. It must call the verifier.
        if code_of "$script" | grep -q "$VERIFIER"; then
            ok "$rel downloads and calls $VERIFIER"
        else
            bad "$rel downloads WITHOUT calling $VERIFIER"
        fi
        continue
    fi

    bad "$rel calls curl directly instead of delegating to $FETCHER"
done < <(find "$PLUGIN" -type f -name '*.sh')

# And every script that installs or execs a binary from ~/bin must have obtained it
# through the fetcher. This is the half that C2 violated: the wrapper exec'd a binary it
# had downloaded itself.
while IFS= read -r script; do
    rel="${script#$ROOT/}"
    base=$(basename "$script")
    [ "$base" = "$FETCHER" ] && continue
    code_of "$script" | grep -qE 'exec "\$BINARY"|chmod \+x' || continue

    if code_of "$script" | grep -q "$FETCHER"; then
        ok "$rel obtains its binary through $FETCHER before running it"
    else
        bad "$rel runs or installs a binary it did not obtain through $FETCHER"
    fi
done < <(find "$PLUGIN" -type f -name '*.sh')

# The verifier must actually be shipped. It lives under plugin/ rather than scripts/
# precisely because scripts/ is repo-only and would not exist on a user's machine.
if [ -f "$PLUGIN/bin/$VERIFIER" ]; then
    ok "$VERIFIER ships inside the plugin"
else
    bad "$VERIFIER is missing from the plugin — callers would fail at runtime"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
