#!/bin/bash
# Keep ~/bin/omlx-claude current at the start of each session.
#
# The MCP server (usage 2) can update itself lazily — Claude Code runs its wrapper every
# time it starts the server. A command the user types has no equivalent moment, so this
# hook is it. It costs nothing when up to date: the version is read locally and no
# network call happens unless the pinned version has moved.
#
# The download, verification and install are in plugin/bin/fetch-release-binary.sh,
# shared with the MCP wrapper. They used to be inline here, which is how the round-2
# hardening ended up applied to this file and not to its twin.
set -u

BINARY_NAME="omlx-claude"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"

# oMLX itself is Apple-silicon only, so a non-arm64 host can never be useful here.
# Stay silent rather than explaining a command they were never going to run.
[[ "$(uname -m)" != "arm64" ]] && exit 0

# Derive the plugin root from this script's own location rather than trusting
# $CLAUDE_PLUGIN_ROOT to be exported into the hook's environment.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
fi

# stdout carries the resolved version; everything the fetcher wants to tell the user is
# already on stderr, which is where a hook's messages belong.
VERSION=$(bash "$PLUGIN_ROOT/bin/fetch-release-binary.sh" "$BINARY_NAME" "$DESIRED_VERSION")
FETCH_STATUS=$?

if [[ $FETCH_STATUS -ne 0 || ! -x "$BINARY" ]]; then
    # The fetcher has already said why on stderr. Nothing is installed, and nothing that
    # was working got destroyed.
    exit 0
fi

# Installed but unreachable is the failure mode people misread as "it didn't install".
# Check once and say the actual fix.
case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        echo "✓ $BINARY_NAME v${VERSION:-unknown} installed: $BINARY"
        ;;
    *)
        echo "✓ $BINARY_NAME v${VERSION:-unknown} installed: $BINARY"
        echo "  ⚠ $INSTALL_DIR is not on your PATH, so typing \`$BINARY_NAME\` will not find it."
        echo "    Add it: echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zshrc"
        ;;
esac
