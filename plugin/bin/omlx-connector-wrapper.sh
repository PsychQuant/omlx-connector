#!/bin/bash
# Resolve the OmlxConnectorMCP binary, downloading it from GitHub Releases when the
# installed copy is missing or older than the version this plugin pins, then exec it.
#
# The download, verification and install are in fetch-release-binary.sh, shared with the
# session-start hook. This file used to carry its own copy of that logic — `curl -sL`
# with no --fail, no checksum, no signature check, `chmod +x` before any verification,
# and a `releases/latest` fallback that recorded the *pinned* version in the marker. When
# review rated that CRITICAL the hook was hardened and this file was not, so the plugin
# shipped one verified binary and one unverified one from the same release. Sharing the
# implementation is the only version of the fix that cannot come apart again.
set -u

BINARY_NAME="OmlxConnectorMCP"
BINARY="$HOME/bin/$BINARY_NAME"

# oMLX itself is Apple-silicon only, so a non-arm64 host can never reach a working
# server. Say that plainly rather than downloading a binary that cannot execute.
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "$BINARY_NAME: requires Apple silicon (detected $(uname -m)). oMLX does not run on Intel Macs." >&2
    exit 1
fi

# Derive the plugin root from this script's own location. $CLAUDE_PLUGIN_ROOT is not
# guaranteed to be present in the environment an MCP server is spawned into.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
fi

# The fetcher writes its messages to stderr and the resolved version to stdout. Both
# matter here: this process's stdout becomes the MCP JSON-RPC stream once we exec, so
# capturing rather than inheriting is what keeps a status line out of the protocol.
bash "$PLUGIN_ROOT/bin/fetch-release-binary.sh" "$BINARY_NAME" "$DESIRED_VERSION" >/dev/null

if [[ ! -x "$BINARY" ]]; then
    # The fetcher has already explained why on stderr. Failing here is correct: there is
    # no server to run, and a silent exit would surface in Claude Code only as "the
    # tools vanished".
    echo "$BINARY_NAME: no verified binary available — not starting." >&2
    exit 1
fi

exec "$BINARY" "$@"
