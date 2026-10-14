#!/bin/bash
# Build LoomDesktop and assemble "Loom Desktop.app", signed, in a directory.
#
#   scripts/bundle-app.sh <out-dir>
#
# make-app.sh installs what this makes; package-release.sh zips it for a
# GitHub release.
#
#   LOOM_UNIVERSAL=1      one binary for Apple silicon and Intel
#   LOOM_VERSION=1.2.3    the version shown (default: the latest v* tag)
#   LOOM_SIGN_IDENTITY=…  the signing identity (default: the keychain's first)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Loom Desktop"
BUNDLE_ID="com.loom.desktop"
OUT_DIR="${1:?usage: scripts/bundle-app.sh <out-dir>}"
mkdir -p "$OUT_DIR"
STAGE="$OUT_DIR/$APP_NAME.app"
rm -rf "$STAGE"

ARCHS=()
[ "${LOOM_UNIVERSAL:-}" = "1" ] && ARCHS=(--arch arm64 --arch x86_64)
echo "▸ building release${ARCHS[*]:+ (arm64 + x86_64)}…"
scripts/swift-build.sh -c release ${ARCHS[@]+"${ARCHS[@]}"} >/dev/null
BINARY="$(scripts/swift-build.sh -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/LoomDesktop"
# An app stamped with an older SDK than it was built against runs in that
# release's compatibility mode, which is how drags once quietly stopped.
BUILT_SDK="$(otool -l "$BINARY" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; exit }')"
if [ "$BUILT_SDK" != "$(xcrun --sdk macosx --show-sdk-version)" ]; then
    echo "✗ LoomDesktop records SDK ${BUILT_SDK:-none}, built against $(xcrun --sdk macosx --show-sdk-version)" >&2
    exit 1
fi

VERSION="${LOOM_VERSION:-$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▸ assembling bundle ($VERSION, build $BUILD)…"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/LoomDesktop"
# Web assets loaded via Bundle.main at runtime: the markdown preview engine
# and the sanitizer it renders through, the diagram renderer and KaTeX it
# fetches when a document has a diagram or a formula, and xterm, which
# renders the agent's pane exactly as the web console does.
cp Resources/marked.min.js Resources/purify.min.js Resources/mermaid.min.js \
   Resources/xterm.js Resources/xterm.css Resources/addon-fit.js \
   Resources/markdown-preview.html Resources/terminal.html \
   "$STAGE/Contents/Resources/"
cp -R Resources/katex "$STAGE/Contents/Resources/"

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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
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
IDENTITY="${LOOM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)}"
SIGN=(--force --deep -s "${IDENTITY:--}")
# Notarization accepts only the hardened runtime and a secure timestamp.
case "$IDENTITY" in "Developer ID Application:"*) SIGN+=(--options runtime --timestamp) ;; esac
echo "▸ signing (${IDENTITY:-ad-hoc})…"
codesign "${SIGN[@]}" "$STAGE"
echo "✓ $STAGE"
