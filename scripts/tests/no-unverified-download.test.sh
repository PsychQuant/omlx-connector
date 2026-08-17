#!/bin/bash
# Nothing shipped in plugin/ may fetch from the network or run a binary out of the install
# directory, except the two files named below.
#
# ## Why this is finally an allowlist
#
# Two earlier versions claimed to be one and were not. The first enumerated violations
# (grep `curl`, grep `chmod +x`); the second added a mechanism list and a path list and a
# `*.sh` glob. All three are denylists — spellings of what is forbidden — and each was
# walked around on the first attempt. The worst case reported **6 passed, 0 failed** with a
# verbatim copy of the round-2 CRITICAL sitting in plugin/hooks/, unenumerated because the
# filename had no `.sh` suffix while hooks.json accepts any executable path.
#
# The allowlist here is over FILES, by repo-relative path:
#
#   - every regular file under plugin/ is enumerated, whatever it is called;
#   - a file that is not on the allowlist must contain no executable code at all;
#   - the two that are permitted are checked for the specific thing each must do.
#
# Extending it means adding a path deliberately. There is no pattern to keep current, and
# no spelling to walk around.
#
# ## And it has cases that must fail
#
# scripts/tests/fixtures/ holds four downloaders, each of which a previous version of this
# scanner reported as clean. They are copied into a throwaway plugin tree and the scanner
# must refuse every one. Without them, deleting a clause here would go unnoticed — which is
# the defect round 5 found: a scanner with no case that must fail.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="$ROOT/scripts/tests/fixtures"
PASS=0
FAIL=0

ok()  { echo "  ok   — $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL — $1"; FAIL=$((FAIL + 1)); }

# Repo-relative paths permitted to contain executable code, and what each must be.
FETCHER_PATH="bin/fetch-release-binary.sh"
VERIFIER_PATH="bin/verify-download.sh"
DELEGATOR_PATHS="bin/omlx-connector-wrapper.sh hooks/session-start.sh"

# Files that are data, not code. Anything else unlisted is a failure by default.
DATA_PATHS=".claude-plugin/plugin.json .mcp.json CLAUDE.md hooks/hooks.json skills/local-delegation/SKILL.md"

in_list() { case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

# Comments describe the defects these files no longer have, so a scan that read prose would
# flag the explanation as the offence — that happened once already.
#
# It must strip TRAILING comments too. Version 3 removed only comments that *start* a line,
# so `: "skipping"   # TODO: call verify-download.sh` satisfied the clause requiring the
# verifier to be run, with every check deleted. Round 2's original defect, third recurrence,
# on the line below a comment naming it.
#
# In shell a `#` opens a comment only at the start of a word, so `${x#y}` and `http://a#b`
# survive. Over-stripping would be the safe direction regardless: it removes text, making a
# clause harder to satisfy rather than easier.
strip_comments() {
    sed -E 's/(^|[[:space:]])#.*$/\1/' "$1" 2>/dev/null | grep -vE '^[[:space:]]*$' || true
}

# Scans one plugin tree. Prints findings; returns non-zero if any file is unaccounted for
# or misbehaves. Used for the real tree and for each adversarial fixture tree.
scan_tree() {
    local plugin="$1" label="$2" quiet="${3:-}" problems=0

    while IFS= read -r file; do
        local rel="${file#$plugin/}"
        local body
        body=$(strip_comments "$file")

        if in_list "$rel" "$DATA_PATHS"; then
            # Data files must not be executable scripts. A hook config pointing at an
            # extensionless downloader is the surface that let the worst rogue through.
            if head -1 "$file" 2>/dev/null | grep -q '^#!'; then
                [ -z "$quiet" ] && bad "$label$rel is listed as data but has a shebang"
                problems=$((problems + 1))
            fi
            continue
        fi

        if [ "$rel" = "$FETCHER_PATH" ]; then
            # The one permitted downloader. It must actually invoke the verifier by path,
            # not merely mention its name — a grep for the name is satisfied by a comment,
            # which is round 2's original defect.
            # An invocation — `bash "$DIR/verify-download.sh" …` — not a mention. Stripping
            # trailing comments already kills a bare mention; requiring the verb makes that
            # independent of how accurate the stripper is.
            if printf '%s' "$body" | grep -qE '(bash|sh|exec|source|\.)[[:space:]]+[^|;&]*verify-download\.sh'; then
                [ -z "$quiet" ] && ok "$label$rel is the permitted downloader and runs the verifier"
            else
                [ -z "$quiet" ] && bad "$label$rel downloads without running the verifier"
                problems=$((problems + 1))
            fi
            continue
        fi

        if [ "$rel" = "$VERIFIER_PATH" ]; then
            [ -z "$quiet" ] && ok "$label$rel is the permitted verifier"
            continue
        fi

        if in_list "$rel" "$DELEGATOR_PATHS"; then
            if printf '%s' "$body" | grep -q "fetch-release-binary.sh"; then
                [ -z "$quiet" ] && ok "$label$rel delegates to the fetcher"
            else
                [ -z "$quiet" ] && bad "$label$rel is a delegator that does not call the fetcher"
                problems=$((problems + 1))
            fi
            continue
        fi

        # Not on any list. That is the finding, regardless of what it contains: an
        # unreviewed executable under plugin/ is exactly how the worst rogue shipped.
        [ -z "$quiet" ] && bad "$label$rel is not on the allowlist — add it deliberately or delegate"
        problems=$((problems + 1))
    done < <(find "$plugin" -type f | sort)

    return $((problems > 0))
}

echo "no unverified downloads in plugin/"
scan_tree "$ROOT/plugin" "" || true

# --- the cases that must fail ------------------------------------------------
# Each fixture is dropped into a copy of the real tree; the scanner must object.
echo
echo "adversarial fixtures (each must be refused)"
if [ ! -d "$FIXTURES" ]; then
    bad "scripts/tests/fixtures/ is missing — the scanner has no case that must fail"
else
    while IFS= read -r fixture; do
        # A fixture's path under fixtures/ IS where it installs under plugin/. Version 3
        # dropped every fixture at plugin/hooks/<basename>, so three of the four clauses
        # never saw a failing case: a fixture written for the fetcher clause landed on an
        # unlisted path and was refused for being unlisted — passing while proving nothing.
        name="${fixture#$FIXTURES/}"

        SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/scanner-fixture-XXXXXX")
        cp -R "$ROOT/plugin" "$SANDBOX/plugin"
        mkdir -p "$SANDBOX/plugin/$(dirname "$name")"
        cp "$fixture" "$SANDBOX/plugin/$name"
        if scan_tree "$SANDBOX/plugin" "" quiet; then
            bad "fixture $name was NOT refused — the scanner would miss it in plugin/"
        else
            ok "fixture $name is refused"
        fi
        rm -rf "$SANDBOX"
    done < <(find "$FIXTURES" -type f ! -name 'README.md' | sort)
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
