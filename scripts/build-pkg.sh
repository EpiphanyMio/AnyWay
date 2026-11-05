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
"$app_dir/Contents/Resources/iphone-venv/bin/python" -c \
    'import pymobiledevice3; from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation'
codesign --verify --deep --strict "$app_dir"

output_dir="$PWD/dist"
mkdir -p "$output_dir"
pkgbuild \
    --component "$app_dir" \
    --install-location /Applications \
    --identifier local.LocationSimulator.pkg \
    --version 1.0 \
    "$output_dir/LocationSimulator-1.0-arm64.pkg"

(cd "$output_dir" && shasum -a 256 LocationSimulator-1.0-arm64.pkg \
    > LocationSimulator-1.0-arm64.pkg.sha256)
printf 'Built: %s\n' "$output_dir/LocationSimulator-1.0-arm64.pkg"
