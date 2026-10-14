#!/bin/bash
# Build the release assets in a directory: LoomDesktop.zip, which install.sh
# downloads, and LoomDesktop.dmg once the app is signed with a Developer ID
# and notarized — the only kind Finder will open from a download.
#
#   scripts/package-release.sh <out-dir>
#
# Notarizes when LOOM_SIGN_IDENTITY is a "Developer ID Application" identity
# and NOTARY_KEY (an App Store Connect API key, the .p8's contents),
# NOTARY_KEY_ID and NOTARY_ISSUER_ID are set.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Loom Desktop"
OUT="${1:?usage: scripts/package-release.sh <out-dir>}"
mkdir -p "$OUT"
LOOM_UNIVERSAL=1 scripts/bundle-app.sh "$OUT"
APP="$OUT/$APP_NAME.app"

notarize() {
    local key
    key="$(mktemp)"
    printf '%s\n' "$NOTARY_KEY" > "$key"
    xcrun notarytool submit "$1" --key "$key" --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" --wait
    rm -f "$key"
}

NOTARIZED=0
if [[ "${LOOM_SIGN_IDENTITY:-}" == "Developer ID Application:"* && -n "${NOTARY_KEY:-}" ]]; then
    echo "▸ notarizing the app…"
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    notarize "$OUT/notarize.zip"
    rm "$OUT/notarize.zip"
    xcrun stapler staple "$APP"
    NOTARIZED=1
fi

echo "▸ zipping…"
rm -f "$OUT/LoomDesktop.zip" "$OUT/LoomDesktop.dmg"
ditto -c -k --keepParent "$APP" "$OUT/LoomDesktop.zip"

if [ "$NOTARIZED" = 1 ]; then
    echo "▸ making the disk image…"
    ROOT="$(mktemp -d)"
    ditto "$APP" "$ROOT/$APP_NAME.app"
    ln -s /Applications "$ROOT/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$ROOT" -format UDZO "$OUT/LoomDesktop.dmg" >/dev/null
    codesign -s "$LOOM_SIGN_IDENTITY" --timestamp "$OUT/LoomDesktop.dmg"
    notarize "$OUT/LoomDesktop.dmg"
    xcrun stapler staple "$OUT/LoomDesktop.dmg"
fi
echo "✓ $(cd "$OUT" && ls LoomDesktop.zip LoomDesktop.dmg 2>/dev/null | tr '\n' ' ')in $OUT"
