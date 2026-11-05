#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -m)" != arm64 ]; then
    echo "This package currently targets Apple Silicon Macs (arm64)." >&2
    exit 1
fi

if [ ! -x .build/iphone-venv/bin/python ]; then
    bash scripts/install-iphone-support.sh
fi

bash scripts/build-app.sh

app_dir="$PWD/.build/LocationSimulator.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
"$app_dir/Contents/Resources/iphone-venv/bin/python" -c \
    'import pymobiledevice3; from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation'
codesign --verify --deep --strict "$app_dir"

output_dir="$PWD/dist"
mkdir -p "$output_dir"
pkg_name="LocationSimulator-$version-arm64.pkg"
pkgbuild \
    --component "$app_dir" \
    --install-location /Applications \
    --identifier local.LocationSimulator.pkg \
    --version "$version" \
    "$output_dir/$pkg_name"

(cd "$output_dir" && shasum -a 256 "$pkg_name" > "$pkg_name.sha256")
printf 'Built: %s\n' "$output_dir/$pkg_name"
