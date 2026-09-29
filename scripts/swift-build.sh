#!/bin/bash
# `swift build`, with the binary stamped with the SDK it was built against.
#
#   scripts/swift-build.sh [swift build arguments…]    # e.g. -c release
#
# Xcode 27's default build engine links through the toolchain's own swiftc
# with no SDKROOT in the environment, and the linker then records the
# deployment target (14.0) as the SDK version. AppKit and SwiftUI read that
# as "built for macOS 14" and run the app in that release's compatibility
# mode: sidebar drags never started, and the window lost the current design.
# Handing the linker the SDK puts the real version back.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --sdk macosx --show-sdk-path)"
exec swift build -Xswiftc -Xclang-linker -Xswiftc "-isysroot$SDK" "$@"
