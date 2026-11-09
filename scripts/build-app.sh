#!/bin/bash
# Builds a release binary and wraps it in build/Disk Visualizer.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Disk Visualizer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
BIN="$APP/Contents/MacOS/DiskVisualizer"
cp "$BIN_DIR/DiskVisualizer" "$BIN"
# SwiftPM stamps the deployment target as the SDK version, and macOS then falls back
# to the old look. Stamp the real SDK so the app gets the current system design.
vtool -set-build-version macos 14.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace -output "$BIN" "$BIN"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DiskVisualizer</string>
    <key>CFBundleIdentifier</key><string>local.disk-visualizer</string>
    <key>CFBundleName</key><string>Disk Visualizer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
