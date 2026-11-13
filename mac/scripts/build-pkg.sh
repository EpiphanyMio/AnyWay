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

app_dir="${ANYWAY_APP_DIR:-$PWD/.build/AnyWay.app}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
"$app_dir/Contents/Resources/iphone-venv/bin/python" -c \
    'import pymobiledevice3; from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation'
codesign --verify --deep --strict "$app_dir"

output_dir="$PWD/dist"
mkdir -p "$output_dir"
pkg_name="AnyWay-$version-arm64.pkg"
# Stage the app as the package root and disable bundle relocation. Otherwise
# Installer may update an older copy outside /Applications instead of placing
# the new app in /Applications.
staging_dir="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/root"
ditto "$app_dir" "$staging_dir/root/AnyWay.app"
cat > "$staging_dir/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>RootRelativeBundlePath</key><string>AnyWay.app</string>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
  </dict>
</array>
</plist>
PLIST
pkgbuild \
    --root "$staging_dir/root" \
    --component-plist "$staging_dir/components.plist" \
    --install-location /Applications \
    --identifier local.AnyWay.pkg \
    --version "$version" \
    "$output_dir/$pkg_name"

(cd "$output_dir" && shasum -a 256 "$pkg_name" > "$pkg_name.sha256")
printf 'Built: %s\n' "$output_dir/$pkg_name"
