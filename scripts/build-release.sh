#!/bin/bash
# Build, sign, and notarize the release binary.
#
# oMLX is Apple-silicon only, so this builds arm64 exclusively — a universal binary
# would carry an x86_64 slice that can never run against a working oMLX server.
#
# Required environment:
#   DEVELOPER_ID    Developer ID Application certificate SHA-1 fingerprint
#   NOTARY_PROFILE  notarytool keychain profile name
#
# Optional:
#   SKIP_NOTARIZE=1  sign but do not submit to Apple (faster local iteration)

set -euo pipefail

BINARY_NAME="OmlxConnectorMCP"
DIST_DIR="dist"

cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${DEVELOPER_ID:?DEVELOPER_ID not set — see README 'Signing & notarization'}"
if [ "${SKIP_NOTARIZE:-}" != "1" ]; then
    : "${NOTARY_PROFILE:?NOTARY_PROFILE not set — see README 'Signing & notarization'}"
fi

VERSION=$(grep -oE 'static let current = "[^"]+"' Sources/OmlxConnectorMCP/Version.swift \
    | head -1 | cut -d'"' -f2)
[ -n "$VERSION" ] || { echo "✗ could not parse version from Version.swift" >&2; exit 1; }
echo "→ building $BINARY_NAME $VERSION (arm64)"

# --- version consistency gate -------------------------------------------------
# Version.swift is the single source of truth. Anything mirroring it must agree, or
# the wrapper will pin a tag whose asset does not exist.
for mirror in plugin/.claude-plugin/plugin.json .claude-plugin/marketplace.json; do
    [ -f "$mirror" ] || continue
    if ! grep -q "\"$VERSION\"" "$mirror"; then
        echo "✗ $mirror does not mention version $VERSION — bump it before releasing" >&2
        exit 1
    fi
done
echo "→ version mirrors agree"

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

# --- checksum -----------------------------------------------------------------
# Computed after signing, because signing changes the bytes.
( cd "$DIST_DIR" && shasum -a 256 "$BINARY_NAME" > "${BINARY_NAME}.sha256" )

echo
echo "✓ $DIST_DIR/$BINARY_NAME  ($VERSION)"
cat "$DIST_DIR/${BINARY_NAME}.sha256"
echo
echo "Next: gh release create v$VERSION $DIST_DIR/$BINARY_NAME $DIST_DIR/${BINARY_NAME}.sha256"
