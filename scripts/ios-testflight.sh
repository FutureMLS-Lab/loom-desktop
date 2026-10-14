#!/bin/bash
# Archive the iOS app and upload it to App Store Connect for TestFlight.
#
#   scripts/ios-testflight.sh
#
# The app record for engineering.loom.ios must already exist in App Store
# Connect. The build number is the time of the build, so each upload is newer
# than the last without editing project.yml.
#
# Given an App Store Connect API key, it signs in with that instead of the
# Apple ID in Xcode, which can sign for the team and still have no access to
# App Store Connect:
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… scripts/ios-testflight.sh
#
# The key is read from ~/.appstoreconnect/private_keys/AuthKey_<id>.p8, or
# from ASC_KEY_PATH.
set -euo pipefail
cd "$(dirname "$0")/../iOS"

AUTH=()
if [ -n "${ASC_KEY_ID:-}" ]; then
    KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
    if [ -z "${ASC_ISSUER_ID:-}" ] || [ ! -f "$KEY_PATH" ]; then
        echo "✗ ASC_KEY_ID needs ASC_ISSUER_ID and the key file at $KEY_PATH" >&2
        exit 1
    fi
    AUTH=(-authenticationKeyPath "$KEY_PATH"
          -authenticationKeyID "$ASC_KEY_ID"
          -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

BUILD_NUMBER="$(date +%y%m%d%H%M)"
ARCHIVE="$HOME/Library/Developer/Xcode/Archives/LoomConsole-$BUILD_NUMBER.xcarchive"

echo "▸ generating project…"
xcodegen generate --quiet

echo "▸ archiving build $BUILD_NUMBER…"
xcodebuild -project Loom.xcodeproj -scheme Loom -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
    ${AUTH[@]+"${AUTH[@]}"} \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive >/dev/null

echo "▸ uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist ExportOptions.plist -exportPath "$(mktemp -d)" \
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}
echo "✓ build $BUILD_NUMBER uploaded; TestFlight lists it once Apple has processed it"
