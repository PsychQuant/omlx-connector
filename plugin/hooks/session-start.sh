#!/bin/bash
# Keep ~/bin/omlx-claude current, downloading it from GitHub Releases when the
# installed copy is missing or older than the version this plugin pins.
#
# The MCP server (usage 2) gets the same treatment from bin/omlx-connector-wrapper.sh,
# but it can do it lazily: Claude Code runs that wrapper every time it starts the
# server. A command the user types has no such moment, so this hook is it.
#
# Costs nothing when up to date: the version marker is read from disk and no
# network call is made unless the pinned version has moved.
set -u

REPO="PsychQuant/omlx-connector"
BINARY_NAME="omlx-claude"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"

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

INSTALLED_VERSION=""
if [[ -f "$VERSION_FILE" ]]; then
    INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
elif [[ -x "$BINARY" ]]; then
    # No marker, but a binary is there — someone installed it by hand or with
    # `make install-omlx-claude`. Ask it directly rather than treating it as
    # unknown, which would re-download it and hit the API on every session.
    INSTALLED_VERSION=$("$BINARY" --version 2>/dev/null | awk '{print $NF}' || true)
fi

NEED_DOWNLOAD=false
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    NEED_DOWNLOAD=true
fi

if $NEED_DOWNLOAD; then
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
        if [[ ! -x "$BINARY" ]]; then
            echo "⚠ $BINARY_NAME: no download URL found at $REPO — install manually from" \
                 "https://github.com/$REPO/releases"
        fi
        # An existing binary is left alone: a stale command still works, and a
        # session-start hook is the wrong place to break someone's day over it.
    elif curl -sL --max-time 300 "$URL" -o "${BINARY}.tmp" 2>/dev/null; then
        chmod +x "${BINARY}.tmp"
        mv "${BINARY}.tmp" "$BINARY"   # atomic: never leaves a half-written binary in place
        echo "${DESIRED_VERSION:-unknown}" > "$VERSION_FILE"
        INSTALLED_VERSION="${DESIRED_VERSION:-unknown}"
        echo "⬆️  $BINARY_NAME updated to v${INSTALLED_VERSION}"
    else
        rm -f "${BINARY}.tmp" 2>/dev/null
        [[ ! -x "$BINARY" ]] && echo "⚠ $BINARY_NAME: download failed and nothing is installed"
    fi
fi

[[ -x "$BINARY" ]] || exit 0

# Installed but unreachable is the failure mode people misread as "it didn't
# install". Check once and say the actual fix.
case ":$PATH:" in
    *":$INSTALL_DIR:"*)
        echo "✓ $BINARY_NAME v${INSTALLED_VERSION:-unknown} installed: $BINARY"
        ;;
    *)
        echo "✓ $BINARY_NAME v${INSTALLED_VERSION:-unknown} installed: $BINARY"
        echo "  ⚠ $INSTALL_DIR is not on your PATH, so typing \`$BINARY_NAME\` will not find it."
        echo "    Add it: echo 'export PATH=\"\$HOME/bin:\$PATH\"' >> ~/.zshrc"
        ;;
esac
