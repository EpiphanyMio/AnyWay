#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/ModuleCache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --cache-path .build/cache
bin_dir="$(swift build -c release --disable-sandbox --cache-path .build/cache --show-bin-path)"
app_dir="$PWD/.build/LocationSimulator.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$bin_dir/LocationSimulator" "$app_dir/Contents/MacOS/LocationSimulator"
cp scripts/iphone_location_bridge.py "$app_dir/Contents/Resources/iphone_location_bridge.py"
bundled_venv="$app_dir/Contents/Resources/iphone-venv"
rm -rf "$bundled_venv"
if [ -x .build/iphone-venv/bin/python ]; then
    mkdir -p "$bundled_venv/bin" "$bundled_venv/lib/python3.9"
    ditto .build/iphone-venv/lib/python3.9/site-packages \
        "$bundled_venv/lib/python3.9/site-packages"
    # Wheel installation records contain this Mac's absolute cache paths.
    find "$bundled_venv/lib/python3.9/site-packages" -type f -name RECORD -delete
    # Load the bundled packages using the target Mac's selected Xcode Python.
    cat > "$bundled_venv/bin/python" <<'PYTHON_LAUNCHER'
#!/bin/sh
set -eu
support_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export PYTHONPATH="$support_dir/lib/python3.9/site-packages"
export PYTHONNOUSERSITE=1
exec "$(xcrun --find python3)" "$@"
PYTHON_LAUNCHER
    chmod 755 "$bundled_venv/bin/python"
fi
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
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app_dir"
printf 'Built: %s\n' "$app_dir"
