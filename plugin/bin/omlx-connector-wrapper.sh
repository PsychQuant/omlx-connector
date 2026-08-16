#!/bin/bash
# Resolve the OmlxConnectorMCP binary, downloading it from GitHub Releases when the
# installed copy is missing or older than the version this plugin pins.
set -u

REPO="PsychQuant/omlx-connector"
BINARY_NAME="OmlxConnectorMCP"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"

# oMLX itself is Apple-silicon only, so a non-arm64 host can never be useful here.
# Say that plainly rather than downloading a binary that cannot execute.
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

INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

NEED_DOWNLOAD=false
REASON=""
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    # Pinned tag first so a plugin version maps to a known binary; fall back to the
    # latest release when that tag has no asset (e.g. a re-cut release).
    URL=""
    for API_URL in \
        "${DESIRED_VERSION:+https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION}" \
        "https://api.github.com/repos/$REPO/releases/latest"
    do
        [[ -z "$API_URL" ]] && continue
        URL=$(curl -sL --max-time 30 "$API_URL" 2>/dev/null \
            | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
            | sed 's/.*"\(https[^"]*\)".*/\1/')
        [[ -n "$URL" ]] && break
    done

    if [[ -z "$URL" ]]; then
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO." >&2
            echo "  Install manually: https://github.com/$REPO/releases" >&2
            exit 1
        fi
    elif curl -sL --max-time 300 "$URL" -o "${BINARY}.tmp" 2>/dev/null; then
        chmod +x "${BINARY}.tmp"
        mv "${BINARY}.tmp" "$BINARY"   # atomic: never leaves a half-written binary in place
        echo "${DESIRED_VERSION:-unknown}" > "$VERSION_FILE"
        echo "$BINARY_NAME: installed v${DESIRED_VERSION:-latest}" >&2
    else
        rm -f "${BINARY}.tmp" 2>/dev/null
        # Degrade to the existing binary rather than failing the server outright: a
        # failed MCP start surfaces in Claude Code only as "the tools vanished".
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — download failed, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — download failed and no existing binary." >&2
            exit 1
        fi
    fi
fi

exec "$BINARY" "$@"
