#!/bin/bash
# Archive the iOS app and upload it to App Store Connect for TestFlight.
#
#   scripts/ios-testflight.sh
#
# The app record for engineering.loom.ios must already exist in App Store
# Connect. The build number is the time of the build, so each upload is newer
# than the last without editing project.yml.
set -euo pipefail
cd "$(dirname "$0")/../iOS"

BUILD_NUMBER="$(date +%y%m%d%H%M)"
ARCHIVE="$HOME/Library/Developer/Xcode/Archives/LoomConsole-$BUILD_NUMBER.xcarchive"

echo "▸ generating project…"
xcodegen generate --quiet

echo "▸ archiving build $BUILD_NUMBER…"
xcodebuild -project Loom.xcodeproj -scheme Loom -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive >/dev/null

echo "▸ uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist ExportOptions.plist -exportPath "$(mktemp -d)" \
    -allowProvisioningUpdates
echo "✓ build $BUILD_NUMBER uploaded; TestFlight lists it once Apple has processed it"
