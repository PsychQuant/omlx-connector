#!/bin/bash
# Decide whether a downloaded file may be installed and executed.
#
#   verify-download.sh <candidate-file> <expected-sha256-file> <team-id>
#
# Exits 0 only when the candidate matches the published checksum AND carries a real
# Developer ID signature from the named team. Prints the reason on any refusal.
#
# This is one file because there are two downloaders. Round 3 found the round-2
# hardening had been applied to plugin/hooks/session-start.sh and not to
# plugin/bin/omlx-connector-wrapper.sh — same plugin, same release, other binary, zero
# verification, and it exec'd what it downloaded. The reported symptom was "the hook
# installs unverified"; the property is "this plugin does not install unverified
# binaries", and a property cannot be established one call site at a time.
set -u

CANDIDATE="${1:?usage: verify-download.sh <file> <sha256-file> <team-id>}"
SUM_FILE="${2:?missing expected-sha256 file}"
TEAM_ID="${3:?missing team id}"

refuse() { echo "$1" >&2; exit 1; }

[ -f "$CANDIDATE" ] || refuse "verify: '$CANDIDATE' does not exist"
[ -f "$SUM_FILE" ]  || refuse "verify: checksum file '$SUM_FILE' does not exist"

EXPECTED=$(awk '{print $1}' "$SUM_FILE" 2>/dev/null)
[ -n "$EXPECTED" ] || refuse "verify: checksum file is empty or unreadable"

ACTUAL=$(shasum -a 256 "$CANDIDATE" 2>/dev/null | awk '{print $1}')
[ -n "$ACTUAL" ] || refuse "verify: could not hash the download"

if [ "$ACTUAL" != "$EXPECTED" ]; then
    refuse "verify: CHECKSUM MISMATCH — expected $EXPECTED, got $ACTUAL"
fi

# A checksum only proves the bytes match the file the release published. It says
# nothing about who published it, so the signature is checked too.
command -v codesign >/dev/null 2>&1 || refuse "verify: codesign unavailable — cannot establish provenance"

# `codesign -R` evaluates a requirement against the actual certificate chain. The
# previous version grepped `codesign -dv` output for `TeamIdentifier=<id>` — and the
# Identifier field is chosen by whoever signs, so a newline inside it puts an arbitrary
# line into that output:
#
#   codesign --force --sign - --identifier "x
#   TeamIdentifier=6W377FS7BS" fake
#
# produced a `TeamIdentifier=6W377FS7BS` line from an ad-hoc signature, and `grep -q`
# does not care where in the output a string appears. scripts/tests/verify-download/
# builds exactly that binary and requires this script to refuse it.
# The leading `=` is required: without it codesign reads the argument as a PATH to a
# requirement file, fails with "invalid requirement specification", and — this is the
# part worth remembering — refuses *everything*. That state passes every negative test
# in the suite while breaking every real install. scripts/tests/verify-download.test.sh
# carries a positive case for exactly this reason; it was the only thing that caught it.
REQUIREMENT="=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\""
if ! codesign --verify --strict -R "$REQUIREMENT" "$CANDIDATE" 2>/dev/null; then
    refuse "verify: not signed by Developer ID team $TEAM_ID — refusing to install"
fi

exit 0
