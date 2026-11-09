#!/bin/bash
# Run the watch app in a watchOS simulator against the mock Loom, and
# photograph it.
#
#   scripts/watch-sim.sh [shot-dir]          # → PNGs, default /tmp/loom-watch/shots
#
# Needs XcodeGen and a watchOS 10+ simulator runtime, which Xcode does not
# install by default:
#
#   xcodebuild -downloadPlatform watchOS
#
# A simulator has no iPhone to hand the watch its servers, so the Debug build
# takes -LoomWatchServer in place of that list. The simulator shares the Mac's
# network: 127.0.0.1 is the Mac, where the mock runs.
#
# A fresh simulator first asks to allow notifications, and that is what the
# first shot shows; answer it once in the simulator window. `simctl privacy`
# cannot grant notifications.
#
#   LOOM_WATCH_OPEN="quant" scripts/watch-sim.sh    # also open a task, by part of its title
#   LOOM_WATCH_DEVICE=<udid> scripts/watch-sim.sh   # a particular simulator
set -euo pipefail
cd "$(dirname "$0")/../iOS"

BUNDLE_ID="engineering.loom.ios.watchkitapp"
# Outside the checkout, which lives in a synced folder.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/LoomWatchSim"
APP="$DERIVED/Build/Products/Debug-watchsimulator/LoomWatch.app"
MOCK_PORT="${LOOM_DEV_MOCK_PORT:-8899}"
SHOTS="${1:-/tmp/loom-watch/shots}"

DEVICE="${LOOM_WATCH_DEVICE:-}"
if [ -z "$DEVICE" ]; then
    # An Apple Watch on the newest watchOS runtime there is, a booted one first.
    DEVICE="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"watchOS-(\d+)-(\d+)", runtime)
    if not match or int(match.group(1)) < 10:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in devices:
        key = (version, device["state"] == "Booted")
        if best is None or key > best[0]:
            best = (key, device["udid"])
print(best[1] if best else "")
')"
fi
if [ -z "$DEVICE" ]; then
    echo "✗ no watchOS 10+ simulator; install one with: xcodebuild -downloadPlatform watchOS" >&2
    exit 1
fi

echo "▸ generating project…"
xcodegen generate --quiet

echo "▸ building…"
# SwiftTerm ships a build plugin, which Xcode asks to trust interactively;
# from the command line the trust is given here.
xcodebuild -project Loom.xcodeproj -scheme LoomWatch -configuration Debug \
    -destination 'generic/platform=watchOS Simulator' -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation -skipMacroValidation build >/dev/null

echo "▸ booting ${DEVICE}…"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

# A mock on a port of its own, so nothing here can reach a real Loom.
STARTED_MOCK=""
if ! curl -s -m 1 "http://127.0.0.1:$MOCK_PORT/api/activity" >/dev/null 2>&1; then
    # Braced: /bin/bash 3.2 reads a name butted against the ellipsis as longer.
    echo "▸ starting mock loom on :${MOCK_PORT}…"
    python3 ../scripts/mock-loom.py "$MOCK_PORT" >/dev/null 2>&1 &
    STARTED_MOCK=$!
    sleep 1
fi

echo "▸ installing and launching…"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
ARGS=(-LoomWatchServer "http://127.0.0.1:$MOCK_PORT")
if [ -n "${LOOM_WATCH_OPEN:-}" ]; then
    ARGS+=(-LoomWatchOpen "$LOOM_WATCH_OPEN")
fi
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null

mkdir -p "$SHOTS"
# Long enough for the activity snapshot, the task names and the first
# conversations read ahead to land.
sleep 8
SHOT="$SHOTS/home.png"
[ -n "${LOOM_WATCH_OPEN:-}" ] && SHOT="$SHOTS/task.png"
xcrun simctl io "$DEVICE" screenshot "$SHOT" >/dev/null 2>&1

# Xcode 27 shows simulators in DeviceHub; earlier ones in Simulator.app.
VIEWER="$(xcode-select -p)/../Applications/DeviceHub.app"
[ -d "$VIEWER" ] || VIEWER="$(xcode-select -p)/Applications/Simulator.app"

echo "✓ $SHOT"
echo "  To use it: open \"$VIEWER\""
if [ -n "$STARTED_MOCK" ]; then
    kill "$STARTED_MOCK" 2>/dev/null || true
    echo "  The mock has stopped with this script; start it first to stay connected:"
    echo "  python3 scripts/mock-loom.py $MOCK_PORT"
fi
