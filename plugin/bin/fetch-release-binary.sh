#!/bin/bash
# Fetch, verify, and install one binary from this project's GitHub releases.
#
#   fetch-release-binary.sh <binary-name> <desired-version|"">
#
# Exit 0 means the binary at ~/bin/<name> is present and trustworthy — either it was
# already current, or it was downloaded and passed both checks. Exit 1 means nothing was
# installed and any existing copy was left alone.
#
# ## Why this is one file
#
# There are two callers: the session-start hook (usage 1's command) and the MCP wrapper
# (usage 2's server). Round 2 of review rated the unverified download CRITICAL, round 3
# found the hardening had been applied to the hook and not to the wrapper — same plugin,
# same release, other binary, still `curl -sL` into `chmod +x` into `exec`.
#
# The reported symptom was "the hook installs unverified". The property is "this plugin
# does not install unverified binaries", and a property cannot be established one call
# site at a time. So the callers no longer own any of this logic; they pass a name.
set -u

BINARY_NAME="${1:?usage: fetch-release-binary.sh <binary-name> [desired-version]}"
DESIRED_VERSION="${2:-}"

REPO="PsychQuant/omlx-connector"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
# Developer ID Team Identifier for this project's releases.
TEAM_ID="6W377FS7BS"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Everything this script says goes to stderr. stdout belongs to the caller: the MCP
# wrapper's stdout is a JSON-RPC stream and a stray line there corrupts the protocol.
say() { echo "$BINARY_NAME: $*" >&2; }

installed_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null
    elif [[ -x "$BINARY" ]]; then
        # No marker but a binary is present — installed by hand or by `make install`.
        # Ask it rather than treating it as unknown, which would re-download and hit
        # the GitHub API on every single session.
        "$BINARY" --version 2>/dev/null | awk '{print $NF}'
    fi
}

INSTALLED_VERSION=$(installed_version)

# Only ever move forward. A plain string inequality downgraded a manually installed
# newer build back to whatever the plugin happened to pin.
is_older_than() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

NEED_DOWNLOAD=false
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
elif [[ -n "$DESIRED_VERSION" ]]; then
    if [[ -z "$INSTALLED_VERSION" ]] || is_older_than "$INSTALLED_VERSION" "$DESIRED_VERSION"; then
        NEED_DOWNLOAD=true
    fi
fi

if ! $NEED_DOWNLOAD; then
    echo "${INSTALLED_VERSION:-unknown}"
    exit 0
fi

# Keeping a stale-but-working binary beats destroying it on the way to failing. A failed
# MCP start surfaces in Claude Code only as "the tools vanished".
give_up() {
    if [[ -x "$BINARY" ]]; then
        say "$1 — keeping the installed v${INSTALLED_VERSION:-unknown}"
        echo "${INSTALLED_VERSION:-unknown}"
        exit 0
    fi
    say "$1 — install manually from https://github.com/$REPO/releases"
    exit 1
}

mkdir -p "$INSTALL_DIR" || give_up "could not create $INSTALL_DIR"

# Resolve the pinned tag only. Falling back to `releases/latest` and then recording the
# *pinned* version in the marker meant a 0.4.0 binary was filed as 0.3.0 and every later
# session believed it was in sync.
API_URL="https://api.github.com/repos/$REPO/releases/latest"
[[ -n "$DESIRED_VERSION" ]] && API_URL="https://api.github.com/repos/$REPO/releases/tags/v${DESIRED_VERSION}"

RELEASE_JSON=$(curl -fsSL --proto '=https' --proto-redir '=https' --max-time 30 \
    "$API_URL" 2>/dev/null) || give_up "release v${DESIRED_VERSION:-latest} not found"

url_for() {
    printf '%s' "$RELEASE_JSON" | grep '"browser_download_url"' \
        | grep "/$1\"" | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/'
}
URL=$(url_for "$BINARY_NAME")
SUM_URL=$(url_for "${BINARY_NAME}.sha256")
[[ -n "$URL" && -n "$SUM_URL" ]] \
    || give_up "release v${DESIRED_VERSION:-latest} is missing the binary or its .sha256"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/${BINARY_NAME}-dl-XXXXXX") || give_up "could not create a scratch directory"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# --fail matters: without it curl exits 0 on an HTTP error and the error page gets
# installed. The checksum would catch that too, but there is no reason to rely on the
# second line of defence for something the first one states outright.
curl -fsSL --proto '=https' --proto-redir '=https' --max-time 300 "$URL" \
    -o "$SCRATCH/$BINARY_NAME" 2>/dev/null || give_up "download failed"
curl -fsSL --proto '=https' --proto-redir '=https' --max-time 30 "$SUM_URL" \
    -o "$SCRATCH/sum" 2>/dev/null || give_up "checksum download failed"

# The single verification both callers share.
VERIFY_OUTPUT=$(bash "$LIB_DIR/verify-download.sh" \
    "$SCRATCH/$BINARY_NAME" "$SCRATCH/sum" "$TEAM_ID" 2>&1) \
    || give_up "${VERIFY_OUTPUT:-verification failed}"

# Ask the binary what it is rather than trusting the tag it came from.
chmod +x "$SCRATCH/$BINARY_NAME" || give_up "could not make the download executable"
ACTUAL_VERSION=$("$SCRATCH/$BINARY_NAME" --version 2>/dev/null | awk '{print $NF}')

# Same filesystem, so this is atomic — the binary is never half-written. Every step is
# checked: writing the marker after a failed move is how "the marker lies about what is
# installed" happened in the first place.
mv "$SCRATCH/$BINARY_NAME" "$BINARY" || give_up "could not install to $BINARY"
FINAL_VERSION="${ACTUAL_VERSION:-${DESIRED_VERSION:-unknown}}"
echo "$FINAL_VERSION" > "$VERSION_FILE" \
    || say "warning: installed v$FINAL_VERSION but could not write $VERSION_FILE (next session will re-check)"

say "installed v${FINAL_VERSION} (checksum + Developer ID verified)"
echo "$FINAL_VERSION"
