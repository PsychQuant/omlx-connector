#!/bin/bash
# Build, sign, notarize, and pack the release artifacts.
#
# oMLX is Apple-silicon only, so this builds arm64 exclusively — a universal binary
# would carry an x86_64 slice that can never run against a working oMLX server.
#
# Produces:
#   dist/OmlxConnectorMCP              signed + notarized binary (GitHub release asset)
#   dist/OmlxConnectorMCP.sha256
#   mcpb/omlx-connector-<version>.mcpb  Claude Desktop bundle
#   mcpb/omlx-connector-<version>.mcpb.sha256
#
# Required environment:
#   DEVELOPER_ID    Developer ID Application certificate SHA-1 fingerprint
#   NOTARY_PROFILE  notarytool keychain profile name
#
# Optional:
#   SKIP_NOTARIZE=1  sign but do not submit to Apple (faster local iteration)

set -euo pipefail

BINARY_NAME="OmlxConnectorMCP"
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
swift build -c release --arch arm64
BUILT=".build/arm64-apple-macosx/release/$BINARY_NAME"
[ -f "$BUILT" ] || BUILT=".build/release/$BINARY_NAME"
[ -f "$BUILT" ] || { echo "✗ built binary not found" >&2; exit 1; }

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp "$BUILT" "$DIST_DIR/$BINARY_NAME"

# --- sign ---------------------------------------------------------------------
# Hardened runtime is required for notarization. No entitlements: this process
# touches no TCC-protected resource, it only speaks HTTP to a loopback address.
echo "→ signing"
codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$DIST_DIR/$BINARY_NAME"
codesign --verify --strict --verbose=1 "$DIST_DIR/$BINARY_NAME"

# --- notarize -----------------------------------------------------------------
if [ "${SKIP_NOTARIZE:-}" = "1" ]; then
    echo "→ SKIP_NOTARIZE=1, not submitting to Apple"
else
    echo "→ notarizing (Apple round-trip is typically 2-10 minutes)"
    ZIP="$DIST_DIR/${BINARY_NAME}-notarize.zip"
    ditto -c -k --keepParent "$DIST_DIR/$BINARY_NAME" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    # Stapling is deliberately skipped: `stapler staple` does not support a bare
    # Mach-O. Gatekeeper resolves the notarization online instead.
fi

# --- checksums (after signing, which changes the bytes) -----------------------
( cd "$DIST_DIR" && shasum -a 256 "$BINARY_NAME" > "${BINARY_NAME}.sha256" )

# --- mcpb bundle --------------------------------------------------------------
# Ship the already-signed binary so the bundle carries a notarized executable.
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
echo "✓ $DIST_DIR/$BINARY_NAME  ($VERSION)"
cat "$DIST_DIR/${BINARY_NAME}.sha256"
echo "✓ $MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb"
cat "$MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb.sha256"
echo
echo "Next: gh release create v$VERSION \\"
echo "        $DIST_DIR/$BINARY_NAME $DIST_DIR/${BINARY_NAME}.sha256 \\"
echo "        $MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb $MCPB_DIR/${BUNDLE_NAME}-${VERSION}.mcpb.sha256"
