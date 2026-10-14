#!/bin/bash
# Build LoomDesktop, package it as "Loom Desktop.app", install and start it.
#
#   scripts/make-app.sh [install-dir]     # default /Applications
#
# Open it from /Applications / Spotlight / Launchpad; quit it from the loom
# menu-bar icon. The bundle is a normal foreground app, not an LSUIElement
# accessory — see the .regular activation policy in App.swift.
#
# bundle-app.sh builds the bundle and install.sh puts it in place — the same
# install a downloaded release gets.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="$(mktemp -d)"
scripts/bundle-app.sh "$STAGE"
scripts/install.sh --app "$STAGE/Loom Desktop.app" --dest "${1:-/Applications}"
