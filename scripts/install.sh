#!/bin/bash
# Install Loom Desktop and start it: the latest GitHub release, or a bundle
# built here.
#
#   curl -fsSL https://raw.githubusercontent.com/FutureMLS-Lab/loom-desktop/main/scripts/install.sh | bash
#   scripts/install.sh --app "path/to/Loom Desktop.app" [--dest DIR]
#
# A release downloaded with curl carries no quarantine flag, so Gatekeeper
# does not stop it even when Apple has not notarized it. LOOM_NO_LAUNCH=1
# installs without starting it or touching the login item.
set -euo pipefail

REPO="FutureMLS-Lab/loom-desktop"
APP_NAME="Loom Desktop"
BUNDLE_ID="com.loom.desktop"
DEST_DIR="/Applications"
APP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --dest) DEST_DIR="$2"; shift 2 ;;
        *) echo "usage: install.sh [--app PATH] [--dest DIR]" >&2; exit 2 ;;
    esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if [ -z "$APP" ]; then
    echo "▸ downloading the latest release…"
    curl -fL --progress-bar -o "$WORK/LoomDesktop.zip" \
        "https://github.com/$REPO/releases/latest/download/LoomDesktop.zip"
    ditto -x -k "$WORK/LoomDesktop.zip" "$WORK"
    APP="$WORK/$APP_NAME.app"
fi
[ -d "$APP" ] || { echo "✗ no app at $APP" >&2; exit 1; }
if ! lipo -archs "$APP/Contents/MacOS/LoomDesktop" | tr ' ' '\n' | grep -qx "$(uname -m)"; then
    echo "✗ this build has no $(uname -m) code" >&2
    exit 1
fi

LAUNCH=1
[ "${LOOM_NO_LAUNCH:-}" = "1" ] && LAUNCH=0
SERVICE="gui/$(id -u)/$BUNDLE_ID"
# Stop the running copy through launchd first: killed under it, the login
# item would bring the old binary straight back.
[ "$LAUNCH" = 1 ] && launchctl bootout "$SERVICE" 2>/dev/null || true
pkill -f "${DEST_DIR}/${APP_NAME}.app/Contents/MacOS/LoomDesktop" 2>/dev/null || true

echo "▸ installing to ${DEST_DIR}…"
mkdir -p "$DEST_DIR"
rm -rf "${DEST_DIR}/${APP_NAME}.app"
ditto "$APP" "${DEST_DIR}/${APP_NAME}.app"
# A copy downloaded in a browser comes flagged, and Finder would refuse it.
xattr -dr com.apple.quarantine "${DEST_DIR}/${APP_NAME}.app" 2>/dev/null || true

# Register the bundle so Spotlight/Finder see this build.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${DEST_DIR}/${APP_NAME}.app" 2>/dev/null || true

if [ "$LAUNCH" = 0 ]; then
    echo "✓ installed:   ${DEST_DIR}/${APP_NAME}.app  (not started)"
    exit 0
fi

# Start it through launchd, not `open`. On this macOS, LaunchServices holds a
# locally built app SIGSTOPped at exec (it never reaches main()), so a
# double-launched app appears as a frozen window that swallows clicks. launchd
# execs it directly and it runs normally. This doubles as the login item.
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array><string>${DEST_DIR}/${APP_NAME}.app/Contents/MacOS/LoomDesktop</string></array>
    <key>RunAtLoad</key><true/>
    <!-- Bring it back when it dies, but not when it meant to go. A plain
         KeepAlive respawns on any exit, which turned Quit into a ten-second
         pause and, worse, put a second instance in a loop: it saw the first,
         exited cleanly, and launchd started it again forever. -->
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardErrorPath</key><string>/tmp/loom-desktop.err.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl kickstart -k "$SERVICE"

echo "✓ installed:   ${DEST_DIR}/${APP_NAME}.app  (runs now, and at login)"
echo "  restart it:  launchctl kickstart -k $SERVICE"
echo "  stop it:     launchctl bootout $SERVICE"
