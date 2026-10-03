#!/bin/bash
# Build the native iOS app (iOS/) and install it on a connected iPhone.
#
#   scripts/ios-install.sh [device-udid]   # default: the first paired iPhone
#
# Needs XcodeGen (brew install xcodegen) and, once per Xcode, the Metal
# toolchain SwiftTerm's shaders compile with:
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "$0")/../iOS"

BUNDLE_ID="engineering.loom.ios"
# Outside the checkout, which lives in a synced folder.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/LoomIOS"
APP="$DERIVED/Build/Products/Release-iphoneos/Loom.app"

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /physical/ { for (i = 1; i <= NF; i++) if (length($i) == 25 && $i ~ /^[0-9A-F]+-[0-9A-F]+$/) { print $i; exit } }')"
fi
if [ -z "$DEVICE" ]; then
    echo "✗ no paired iPhone found; pass its UDID" >&2
    exit 1
fi

echo "▸ generating project…"
xcodegen generate --quiet

echo "▸ building release…"
# SwiftTerm ships a build plugin, which Xcode asks to trust interactively;
# from the command line the trust is given here.
xcodebuild -project Loom.xcodeproj -scheme Loom -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation -skipMacroValidation \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    build >/dev/null

echo "▸ installing on $DEVICE…"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null
echo "✓ installed and launched"
