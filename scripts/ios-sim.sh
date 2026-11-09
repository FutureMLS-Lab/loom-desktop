#!/bin/bash
# Run the native iOS app in an iPhone simulator against the mock Loom, and
# photograph it.
#
#   scripts/ios-sim.sh [shot-dir]          # → PNGs, default /tmp/loom-ios/shots
#
# The simulator gets its server seeded straight into the app's prefs (a mock
# entry under the loomServers key): no tapping through onboarding. The
# simulator shares the Mac's network: 127.0.0.1 is the Mac, where the mock
# runs.
#
#   LOOM_IOS_OPEN="quant" scripts/ios-sim.sh    # also open a task, by part of its title
#   LOOM_IOS_DEVICE=<udid> scripts/ios-sim.sh   # a particular simulator
set -euo pipefail
cd "$(dirname "$0")/../iOS"

BUNDLE_ID="engineering.loom.ios"
# Outside the checkout, which lives in a synced folder.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/LoomIOSSim"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Loom.app"
MOCK_PORT="${LOOM_DEV_MOCK_PORT:-8899}"
SHOTS="${1:-/tmp/loom-ios/shots}"

DEVICE="${LOOM_IOS_DEVICE:-}"
if [ -z "$DEVICE" ]; then
    # An iPhone on the newest iOS runtime there is, a booted one first.
    DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in devices:
        if "iPhone" not in device.get("name", ""):
            continue
        key = (version, device["state"] == "Booted")
        if best is None or key > best[0]:
            best = (key, device["udid"])
print(best[1] if best else "")
')"
fi
if [ -z "$DEVICE" ]; then
    echo "✗ no available iPhone simulator" >&2
    exit 1
fi

echo "▸ generating project…"
xcodegen generate --quiet

echo "▸ building…"
# SwiftTerm ships a build plugin, which Xcode asks to trust interactively;
# from the command line the trust is given here.
xcodebuild -project Loom.xcodeproj -scheme Loom -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation -skipMacroValidation build >/dev/null

echo "▸ booting ${DEVICE}…"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

# A mock on a port of its own, so nothing here can reach a real Loom.
STARTED_MOCK=""
if ! curl -s -m 1 "http://127.0.0.1:$MOCK_PORT/api/activity" >/dev/null 2>&1; then
    echo "▸ starting mock loom on :${MOCK_PORT}…"
    python3 ../scripts/mock-loom.py "$MOCK_PORT" >/dev/null 2>&1 &
    STARTED_MOCK=$!
    sleep 1
fi

echo "▸ installing…"
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

# Seed the mock server straight into the app's prefs: WorkspaceStore only
# leaves onboarding when the loomServers key exists.
echo "▸ seeding mock server…"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
PREFS="$CONTAINER/Library/Preferences/$BUNDLE_ID.plist"
mkdir -p "$(dirname "$PREFS")"
MOCK_URL="http://127.0.0.1:$MOCK_PORT" python3 - "$PREFS" <<'EOF'
import json, os, plistlib, sys
prefs_path, url = sys.argv[1], os.environ["MOCK_URL"]
server = [{"id": "mock", "name": "Mock Loom", "baseURL": url, "token": ""}]
data = {}
if os.path.exists(prefs_path):
    with open(prefs_path, "rb") as f:
        try:
            data = plistlib.load(f)
        except Exception:
            data = {}
data["loomServers"] = json.dumps(server).encode()
data["loomActiveServer"] = "mock"
with open(prefs_path, "wb") as f:
    plistlib.dump(data, f)
print("seeded", prefs_path)
EOF

echo "▸ launching…"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
ARGS=()
if [ -n "${LOOM_IOS_OPEN:-}" ]; then
    ARGS+=(-LoomOpenTask "$LOOM_IOS_OPEN")
fi
if [ "${#ARGS[@]}" -gt 0 ]; then
    xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null
else
    xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
fi

mkdir -p "$SHOTS"
# Long enough for the workspace, the activity snapshot and the first
# conversation read-ahead to land.
sleep 10
SHOT="$SHOTS/phone.png"
[ -n "${LOOM_IOS_OPEN:-}" ] && SHOT="$SHOTS/phone-task.png"
xcrun simctl io "$DEVICE" screenshot "$SHOT" >/dev/null 2>&1

echo "✓ $SHOT"
if [ -n "$STARTED_MOCK" ]; then
    kill "$STARTED_MOCK" 2>/dev/null || true
    echo "  The mock has stopped with this script; start it first to stay connected:"
    echo "  python3 scripts/mock-loom.py $MOCK_PORT"
fi
