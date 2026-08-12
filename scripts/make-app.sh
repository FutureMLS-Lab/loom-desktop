#!/bin/bash
# Build LoomDesktop and package it as "Loom Desktop.app".
#
#   scripts/make-app.sh [install-dir]     # default /Applications
#
# Open it from /Applications / Spotlight / Launchpad; quit it from the loom
# menu-bar icon. The bundle is a normal foreground app, not an LSUIElement
# accessory — see the .regular activation policy in App.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Loom Desktop"
BUNDLE_ID="com.loom.desktop"
DEST_DIR="${1:-/Applications}"
STAGE="$(mktemp -d)/$APP_NAME.app"

echo "▸ building release…"
swift build -c release >/dev/null

echo "▸ assembling bundle…"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/LoomDesktop "$STAGE/Contents/MacOS/LoomDesktop"
# Web assets loaded via Bundle.main at runtime: the markdown preview engine
# and xterm, which renders the agent's pane exactly as the web console does.
cp Resources/marked.min.js Resources/xterm.js Resources/xterm.css Resources/addon-fit.js \
   "$STAGE/Contents/Resources/"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>LoomDesktop</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# App icon: the vendored copy, falling back to the loom-app assets when this
# lives inside the wider Loom checkout.
ICON_SRC="Resources/loom-icon.png"
[ -f "$ICON_SRC" ] || ICON_SRC="../loom-app/packages/loom-app/assets/loom-icon.png"
if [ -f "$ICON_SRC" ]; then
    # Same art doubles as the watermark behind empty panes.
    cp "$ICON_SRC" "$STAGE/Contents/Resources/loom-mark.png"
    echo "▸ building icon…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
fi

# Prefer a real signing identity (Gatekeeper rejects ad-hoc bundles launched
# via Finder/LaunchServices on newer macOS — the process hangs suspended at
# dyld); fall back to ad-hoc when none is available.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
echo "▸ signing (${IDENTITY:-ad-hoc})…"
codesign --force --deep -s "${IDENTITY:--}" "$STAGE"

echo "▸ installing to ${DEST_DIR}..."
pkill -f "${APP_NAME}.app/Contents/MacOS/LoomDesktop" 2>/dev/null || true
rm -rf "${DEST_DIR}/${APP_NAME}.app"
ditto "$STAGE" "${DEST_DIR}/${APP_NAME}.app"

# Register the bundle so Spotlight/Finder see this build.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${DEST_DIR}/${APP_NAME}.app" 2>/dev/null || true

# Start it through launchd, not `open`. On this macOS, LaunchServices holds a
# locally built app SIGSTOPped at exec (it never reaches main()), so a
# double-launched app appears as a frozen window that swallows clicks. launchd
# execs it directly and it runs normally. This doubles as the login item.
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array><string>${DEST_DIR}/${APP_NAME}.app/Contents/MacOS/LoomDesktop</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>/tmp/loom-desktop.err.log</string>
</dict>
</plist>
EOF

if [ "${LOOM_NO_LAUNCH:-}" != "1" ]; then
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
        || launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID"
fi

echo "✓ installed:   ${DEST_DIR}/${APP_NAME}.app  (runs now, and at login)"
echo "  restart it:  launchctl kickstart -k gui/\$(id -u)/$BUNDLE_ID"
echo "  stop it:     launchctl bootout gui/\$(id -u)/$BUNDLE_ID"
