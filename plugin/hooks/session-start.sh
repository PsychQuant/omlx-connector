#!/bin/bash
# Keep ~/bin/omlx-claude current, downloading it from GitHub Releases when the
# installed copy is missing or older than the version this plugin pins.
#
# The MCP server (usage 2) gets the same treatment from bin/omlx-connector-wrapper.sh,
# but it can do it lazily: Claude Code runs that wrapper every time it starts the
# server. A command the user types has no such moment, so this hook is it.
#
# Nothing is installed without being verified first. The first cut of this file did
# `curl -sL` → `chmod +x` → `mv`, with no checksum, no signature, and no --fail — which
# review rated CRITICAL, and rightly: the release publishes a .sha256 for every binary
# and this script ignored it, while an HTTP error page would have been installed over a
# working binary and then executed on the next `omlx-claude`.
set -u

REPO="PsychQuant/omlx-connector"
BINARY_NAME="omlx-claude"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
# Developer ID Team Identifier for this project's releases. A checksum alone proves the
# download matches the release; only the signature proves who built it.
EXPECTED_TEAM_ID="6W377FS7BS"

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
    # No marker, but a binary is there — installed by hand or with
    # `make install-omlx-claude`. Ask it directly rather than treating it as unknown,
    # which would re-download and hit the API on every session.
    INSTALLED_VERSION=$("$BINARY" --version 2>/dev/null | awk '{print $NF}' || true)
fi

# Sorts two versions and reports whether $1 is strictly older than $2. Used so a
# manually installed newer build is never quietly rolled back to the pinned one.
is_older_than() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

NEED_DOWNLOAD=false
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
elif [[ -n "$DESIRED_VERSION" && -n "$INSTALLED_VERSION" ]] \
    && is_older_than "$INSTALLED_VERSION" "$DESIRED_VERSION"; then
    NEED_DOWNLOAD=true
elif [[ -n "$DESIRED_VERSION" && -z "$INSTALLED_VERSION" ]]; then
    NEED_DOWNLOAD=true
fi

if $NEED_DOWNLOAD; then
    mkdir -p "$INSTALL_DIR"

    # Resolve the pinned tag only. The old code fell back to `releases/latest` when the
    # pinned tag had no asset, downloaded whatever that was, and then wrote the PINNED
    # version into the marker — so a 0.4.0 binary was recorded as 0.3.0 and every later
    # session believed it was in sync. A missing asset is now a visible failure.
    ASSET_VERSION="$DESIRED_VERSION"
    API_URL="https://api.github.com/repos/$REPO/releases/tags/v${DESIRED_VERSION}"
    [[ -z "$DESIRED_VERSION" ]] && API_URL="https://api.github.com/repos/$REPO/releases/latest"

    RELEASE_JSON=$(curl -fsSL --proto '=https' --proto-redir '=https' --max-time 30 \
        "$API_URL" 2>/dev/null)
    if [[ -z "$DESIRED_VERSION" && -n "$RELEASE_JSON" ]]; then
        ASSET_VERSION=$(printf '%s' "$RELEASE_JSON" \
            | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
    fi

    url_for() {
        printf '%s' "$RELEASE_JSON" | grep '"browser_download_url"' \
            | grep "/$1\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/'
    }
    URL=$(url_for "$BINARY_NAME")
    SUM_URL=$(url_for "${BINARY_NAME}.sha256")

    fail_soft() {
        # A stale-but-working binary is better than a broken one: never destroy what is
        # already installed on the way to failing.
        if [[ -x "$BINARY" ]]; then
            echo "⚠ $BINARY_NAME: $1 — keeping the installed v${INSTALLED_VERSION:-unknown}"
        else
            echo "⚠ $BINARY_NAME: $1 — install manually from https://github.com/$REPO/releases"
        fi
    }

    if [[ -z "$URL" || -z "$SUM_URL" ]]; then
        fail_soft "release v${DESIRED_VERSION:-latest} is missing the binary or its .sha256"
    else
        TMPDIR_DL=$(mktemp -d "${TMPDIR:-/tmp}/omlx-claude-dl-XXXXXX")
        # Download into a scratch directory, verify there, and only then replace the
        # installed copy. Nothing touches $BINARY until every check has passed.
        if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-time 300 \
            "$URL" -o "$TMPDIR_DL/$BINARY_NAME" 2>/dev/null; then
            fail_soft "download failed"
        elif ! curl -fsSL --proto '=https' --proto-redir '=https' --max-time 30 \
            "$SUM_URL" -o "$TMPDIR_DL/sum" 2>/dev/null; then
            fail_soft "checksum download failed"
        elif ! EXPECTED_SUM=$(awk '{print $1}' "$TMPDIR_DL/sum") \
            || [[ -z "$EXPECTED_SUM" ]] \
            || [[ "$(shasum -a 256 "$TMPDIR_DL/$BINARY_NAME" | awk '{print $1}')" != "$EXPECTED_SUM" ]]; then
            fail_soft "CHECKSUM MISMATCH — refusing to install"
        elif ! codesign --verify --strict "$TMPDIR_DL/$BINARY_NAME" 2>/dev/null; then
            fail_soft "code signature is invalid — refusing to install"
        elif ! codesign -dv "$TMPDIR_DL/$BINARY_NAME" 2>&1 \
            | grep -q "TeamIdentifier=$EXPECTED_TEAM_ID"; then
            # A checksum only proves the bytes match the release. If the release itself
            # were replaced, both would agree — the Team ID is what makes that visible.
            fail_soft "not signed by the expected Developer ID team — refusing to install"
        else
            chmod +x "$TMPDIR_DL/$BINARY_NAME"
            # Ask the binary what it is, rather than trusting the tag it came from.
            ACTUAL_VERSION=$("$TMPDIR_DL/$BINARY_NAME" --version 2>/dev/null | awk '{print $NF}')
            mv "$TMPDIR_DL/$BINARY_NAME" "$BINARY"   # atomic within the same filesystem
            INSTALLED_VERSION="${ACTUAL_VERSION:-${ASSET_VERSION:-unknown}}"
            echo "$INSTALLED_VERSION" > "$VERSION_FILE"
            echo "⬆️  $BINARY_NAME updated to v${INSTALLED_VERSION} (checksum + signature verified)"
        fi
        rm -rf "$TMPDIR_DL"
    fi
fi

[[ -x "$BINARY" ]] || exit 0

# Installed but unreachable is the failure mode people misread as "it didn't install".
# Check once and say the actual fix.
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
