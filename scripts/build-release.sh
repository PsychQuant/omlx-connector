#!/bin/bash
# Build, sign, notarize, and pack the release artifacts.
#
# oMLX is Apple-silicon only, so this builds arm64 exclusively — a universal binary
# would carry an x86_64 slice that can never run against a working oMLX server.
#
# Produces:
#   dist/OmlxConnectorMCP              signed + notarized binary (GitHub release asset)
#   dist/OmlxConnectorMCP.sha256
#   dist/omlx-claude                   signed + notarized binary (GitHub release asset)
#   dist/omlx-claude.sha256
#   mcpb/omlx-connector-<version>.mcpb  Claude Desktop bundle
#   mcpb/omlx-connector-<version>.mcpb.sha256
#
# The .mcpb bundle carries the MCP server only. Claude Desktop has no terminal, so
# a command-line launcher would be dead weight inside it — omlx-claude reaches
# users through the plugin's session-start hook or `make install-omlx-claude`.
#
# Required environment:
#   DEVELOPER_ID    Developer ID Application certificate SHA-1 fingerprint
#   NOTARY_PROFILE  notarytool keychain profile name
#
# Optional:
#   SKIP_NOTARIZE=1  sign but do not submit to Apple (faster local iteration)

set -euo pipefail

BINARY_NAME="OmlxConnectorMCP"
LAUNCHER_NAME="omlx-claude"
RELEASE_BINARIES=("$BINARY_NAME" "$LAUNCHER_NAME")
BUNDLE_NAME="omlx-connector"
DIST_DIR="dist"
MCPB_DIR="mcpb"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${DEVELOPER_ID:?DEVELOPER_ID not set — see README 'Signing & notarization'}"
if [ "${SKIP_NOTARIZE:-}" != "1" ]; then
    : "${NOTARY_PROFILE:?NOTARY_PROFILE not set — see README 'Signing & notarization'}"
fi

VERSION=$(grep -oE 'static let current = "[^"]+"' Sources/OmlxConnectorCore/Version.swift \
    | head -1 | cut -d'"' -f2)
[ -n "$VERSION" ] || { echo "✗ could not parse version from Version.swift" >&2; exit 1; }
echo "→ building $BINARY_NAME $VERSION (arm64)"

# --- version consistency gate -------------------------------------------------
# Version.swift is the single source of truth. A mirror that disagrees is not a
# cosmetic problem: the plugin wrapper pins the release tag by plugin.json version,
# so a mismatch sends users to a tag whose asset does not exist.
for mirror in \
    plugin/.claude-plugin/plugin.json \
    .claude-plugin/marketplace.json \
    "$MCPB_DIR/manifest.json"
do
    [ -f "$mirror" ] || continue
    if ! grep -q "\"$VERSION\"" "$mirror"; then
        echo "✗ $mirror does not mention version $VERSION — bump it before releasing" >&2
        exit 1
    fi
done

# The MCP server advertises this name at runtime; Claude Desktop silently drops a
# server whose serverInfo.name disagrees with the bundle manifest, which is a
# miserable failure to diagnose from the outside.
# Lives with the MCP executable, not in the shared library: the name describes one
# command, and OmlxConnectorCore is shared by every executable in the module.
SERVER_NAME=$(grep -oE 'static let mcpServerName = "[^"]+"' Sources/OmlxConnectorMCP/Identity.swift \
    | head -1 | cut -d'"' -f2)
MANIFEST_NAME=$(python3 -c "import json;print(json.load(open('$MCPB_DIR/manifest.json'))['name'])" 2>/dev/null || echo "")
if [ -n "$MANIFEST_NAME" ] && [ "$SERVER_NAME" != "$MANIFEST_NAME" ]; then
    echo "✗ mcpServerName ('$SERVER_NAME') != manifest name ('$MANIFEST_NAME')" >&2
    echo "  Claude Desktop drops the server entirely on this mismatch." >&2
    exit 1
fi
echo "→ version and name mirrors agree"

# --- build --------------------------------------------------------------------
# One build produces every executable product in the package.
swift build -c release --arch arm64

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
for binary in "${RELEASE_BINARIES[@]}"; do
    BUILT=".build/arm64-apple-macosx/release/$binary"
    [ -f "$BUILT" ] || BUILT=".build/release/$binary"
    [ -f "$BUILT" ] || { echo "✗ built binary not found: $binary" >&2; exit 1; }
    cp "$BUILT" "$DIST_DIR/$binary"
done

# --- sign ---------------------------------------------------------------------
# Hardened runtime is required for notarization. No entitlements: neither process
# touches a TCC-protected resource — one speaks HTTP to a loopback address, the
# other execs a launcher.
echo "→ signing"
for binary in "${RELEASE_BINARIES[@]}"; do
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID" "$DIST_DIR/$binary"
    codesign --verify --strict --verbose=1 "$DIST_DIR/$binary"
done

# --- notarize -----------------------------------------------------------------
if [ "${SKIP_NOTARIZE:-}" = "1" ]; then
    echo "→ SKIP_NOTARIZE=1, not submitting to Apple"
else
    # One submission covering both binaries, not one each. Apple notarizes every
    # Mach-O it finds in the archive, so a second executable costs no extra
    # round-trip — which is worth arranging, since each one is 2-10 minutes.
    echo "→ notarizing ${#RELEASE_BINARIES[@]} binaries (Apple round-trip is typically 2-10 minutes)"
    # The archive is built OUTSIDE the directory it archives. Writing it into
    # $DIST_DIR meant ditto was recursively reading a tree containing its own
    # growing output — depending on traversal order that yields a corrupt archive
    # or a failed build, and SKIP_NOTARIZE=1 is precisely the flag that hides it.
    NOTARIZE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/omlx-notarize-XXXXXX")
    trap 'rm -rf "$NOTARIZE_TMP"' EXIT
    ZIP="$NOTARIZE_TMP/notarize.zip"
    ditto -c -k "$DIST_DIR" "$ZIP"

    # Confirm the archive actually holds both binaries before spending an Apple
    # round-trip on it. A short archive still notarizes fine — it just silently
    # leaves one binary unnotarized, which surfaces on a user's machine, not here.
    for binary in "${RELEASE_BINARIES[@]}"; do
        unzip -l "$ZIP" | grep -q "[/ ]$binary\$" \
            || { echo "✗ $binary missing from the notarization archive" >&2; exit 1; }
    done

    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -rf "$NOTARIZE_TMP"
    trap - EXIT
    # Stapling is deliberately skipped: `stapler staple` does not support a bare
    # Mach-O. Gatekeeper resolves the notarization online instead.
fi

# --- checksums (after signing, which changes the bytes) -----------------------
for binary in "${RELEASE_BINARIES[@]}"; do
    ( cd "$DIST_DIR" && shasum -a 256 "$binary" > "${binary}.sha256" )
done

# --- mcpb bundle --------------------------------------------------------------
# Ship the already-signed binary so the bundle carries a notarized executable.
# Only the MCP server goes in: Claude Desktop has no terminal for omlx-claude to
# be typed into, so shipping it here would add weight nobody could reach.
echo "→ packing mcpb bundle"
mkdir -p "$MCPB_DIR/server"
rm -f "$MCPB_DIR/server/$BINARY_NAME"   # fresh inode: codesign hashes are cached per inode
cp "$DIST_DIR/$BINARY_NAME" "$MCPB_DIR/server/$BINARY_NAME"

( cd "$MCPB_DIR" \
    && mcpb validate manifest.json \
    && rm -f "${BUNDLE_NAME}-${VERSION}.mcpb" \
    && mcpb pack . "${BUNDLE_NAME}-${VERSION}.mcpb" \
    && shasum -a 256 "${BUNDLE_NAME}-${VERSION}.mcpb" > "${BUNDLE_NAME}-${VERSION}.mcpb.sha256" )

echo
for binary in "${RELEASE_BINARIES[@]}"; do
    echo "✓ $DIST_DIR/$binary  ($VERSION)"
    cat "$DIST_DIR/${binary}.sha256"
done
echo "✓ $MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb"
cat "$MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb.sha256"
echo
# Every asset named here is matched by exact filename downstream — the plugin's
# wrapper and session-start hook both look the binaries up by name — so an
# omission surfaces as a download error pointing nowhere useful.
echo "Next: gh release create v$VERSION \\"
for binary in "${RELEASE_BINARIES[@]}"; do
    echo "        $DIST_DIR/$binary $DIST_DIR/${binary}.sha256 \\"
done
echo "        $MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb $MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb.sha256"
