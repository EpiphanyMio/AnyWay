#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/.build/LocationSimulator.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$bin_dir/LocationSimulator" "$app_dir/Contents/MacOS/LocationSimulator"
cp scripts/iphone_location_bridge.py "$app_dir/Contents/Resources/iphone_location_bridge.py"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LocationSimulator</string>
    <key>CFBundleIdentifier</key><string>local.LocationSimulator</string>
    <key>CFBundleName</key><string>LocationSimulator</string>
    <key>CFBundleDisplayName</key><string>定位模拟器</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app_dir"
printf 'Built: %s\n' "$app_dir"
