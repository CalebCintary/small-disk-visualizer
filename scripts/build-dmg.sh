#!/bin/bash
# Builds the app and packs it into a drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DMG="build/DiskVisualizer-1.0-arm64.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

ditto --norsrc "build/Disk Visualizer.app" "$STAGING/Disk Visualizer.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Disk Visualizer" -srcfolder "$STAGING" -format UDZO -fs HFS+ -ov "$DMG"
echo "Built: $DMG"
