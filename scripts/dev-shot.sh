#!/bin/bash
# Photograph a work-in-progress build without touching the installed app.
#
#   scripts/dev-shot.sh [snapshot-dir]        # → PNGs, default /tmp/loom-dev/snaps
#
# make-app.sh is the wrong tool while iterating: it kills the running app and
# replaces /Applications. This builds debug, assembles a bundle under its own
# id (com.loom.desktop.dev — its own defaults domain, and the single-instance
# check lets it run beside the real one), points it at a mock Loom, and runs
# it long enough for LOOM_DESKTOP_SNAPSHOT_DIR to fire.
#
# The usual dev hooks pass straight through, e.g.:
#
#   LOOM_DESKTOP_OPEN_CHAT="p1/quant-eval" scripts/dev-shot.sh
#   LOOM_DESKTOP_OPEN_WINDOWS=settings scripts/dev-shot.sh
#
# Run the bundle's binary directly, never `open`: LaunchServices suspends
# locally built apps on this machine (see make-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.loom.desktop.dev"
APP="/tmp/loom-dev/Loom Desktop Dev.app"
MOCK_PORT="${LOOM_DEV_MOCK_PORT:-8899}"
SHOTS="${1:-/tmp/loom-dev/snaps}"

echo "▸ building debug…"
swift build >/dev/null

echo "▸ assembling dev bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/LoomDesktop "$APP/Contents/MacOS/LoomDesktop"
cp Resources/marked.min.js Resources/xterm.js Resources/xterm.css \
   Resources/addon-fit.js Resources/markdown-preview.html Resources/terminal.html \
   "$APP/Contents/Resources/"
cp Resources/loom-icon.png "$APP/Contents/Resources/loom-mark.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Loom Desktop Dev</string>
    <key>CFBundleExecutable</key><string>LoomDesktop</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" 2>/dev/null

# A mock on a port of its own, so nothing here can reach a real Loom.
STARTED_MOCK=""
if ! curl -s -m 1 "http://127.0.0.1:$MOCK_PORT/api/activity" >/dev/null 2>&1; then
    echo "▸ starting mock loom on :$MOCK_PORT…"
    python3 scripts/mock-loom.py "$MOCK_PORT" >/dev/null 2>&1 &
    STARTED_MOCK=$!
    sleep 1
fi

defaults write "$BUNDLE_ID" loomBaseURL "http://127.0.0.1:$MOCK_PORT"
defaults write "$BUNDLE_ID" loomAuthToken ""
defaults write "$BUNDLE_ID" panelHidden -bool false

mkdir -p "$SHOTS"
rm -f "$SHOTS"/window-*.png

echo "▸ running (snapshots land ~7s in)…"
LOOM_DESKTOP_SNAPSHOT_DIR="$SHOTS" \
LOOM_DESKTOP_OPEN_CHAT="${LOOM_DESKTOP_OPEN_CHAT:-p1/video2bit}" \
    "$APP/Contents/MacOS/LoomDesktop" &
APP_PID=$!
sleep 13
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
[ -n "$STARTED_MOCK" ] && kill "$STARTED_MOCK" 2>/dev/null || true

echo "✓ snapshots:"
ls "$SHOTS"/window-*.png
