#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .build/ModuleCache .build/cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release --disable-sandbox --cache-path .build/cache
bin_dir="$(swift build -c release --disable-sandbox --cache-path .build/cache --show-bin-path)"
app_dir="${ANYWAY_APP_DIR:-$PWD/.build/AnyWay.app}"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$bin_dir/AnyWay" "$app_dir/Contents/MacOS/AnyWay"
cp scripts/iphone_location_bridge.py "$app_dir/Contents/Resources/iphone_location_bridge.py"
cp scripts/iphone_wireless.py "$app_dir/Contents/Resources/iphone_wireless.py"
cp ../RELEASE_NOTES.json "$app_dir/Contents/Resources/RELEASE_NOTES.json"
python3 ../scripts/build_icns.py ../assets/app-icon-macos.png \
    "$app_dir/Contents/Resources/AnyWay.icns"
if [ -f android/app/build/outputs/apk/debug/app-debug.apk ]; then
    cp android/app/build/outputs/apk/debug/app-debug.apk \
        "$app_dir/Contents/Resources/AnyWay-Android.apk"
fi
bundled_venv="$app_dir/Contents/Resources/iphone-venv"
rm -rf "$bundled_venv"
if [ -x .build/iphone-venv/bin/python ]; then
    bash scripts/install-iphone-support.sh
    ditto .build/iphone-venv "$bundled_venv"
    # Only the interpreter is launched from the app. pip-generated scripts
    # point to the staging directory and cannot be relocated.
    find "$bundled_venv/bin" -maxdepth 1 ! -type d ! -name 'python3' ! -name 'python3.13' -delete
    cat > "$bundled_venv/bin/python" <<'PYTHON_LAUNCHER'
#!/bin/sh
exec "$(dirname "$0")/python3" -E -s -B "$@"
PYTHON_LAUNCHER
    chmod 755 "$bundled_venv/bin/python"
fi
version="$(cat ../VERSION)"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AnyWay</string>
    <key>CFBundleIdentifier</key><string>local.AnyWay</string>
    <key>CFBundleName</key><string>AnyWay</string>
    <key>CFBundleDisplayName</key><string>AnyWay</string>
    <key>CFBundleIconFile</key><string>AnyWay.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSLocalNetworkUsageDescription</key><string>AnyWay 通过局域网查找并连接已配对的 iPhone，以使用开发者定位服务。</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app_dir"
printf 'Built: %s\n' "$app_dir"

