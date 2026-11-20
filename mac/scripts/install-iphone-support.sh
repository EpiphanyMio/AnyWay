#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# RemotePairing uses TLS-PSK. Package the interpreter with its OpenSSL so the
# installed app can negotiate the same tunnel as the development build.
version=3.13.18
release=20261110
case "$(uname -m)" in
    arm64) arch=aarch64; sha=7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540 ;;
    x86_64) arch=x86_64; sha=d27d59a722db9f69926eb6d9564071247221f45a04da920ea7f3001c97e32f9b ;;
    *) echo "Unsupported Mac architecture" >&2; exit 1 ;;
esac
bridge_version=11.50.0
runtime="$PWD/.build/iphone-venv"
stamp="$version-$release-$arch-$bridge_version"
if [[ -x "$runtime/bin/python" && -f "$runtime/anyway-runtime" && "$(cat "$runtime/anyway-runtime")" == "$stamp" ]]; then
    exit 0
fi

mkdir -p .build
stage="$(mktemp -d "$PWD/.build/iphone-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
archive=".build/cpython-$version-$arch.tar.gz"
asset="cpython-$version%2B$release-$arch-apple-darwin-install_only_stripped.tar.gz"
if ! printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c - >/dev/null 2>&1; then
    curl -fLsS --retry 2 "https://github.com/astral-sh/python-build-standalone/releases/download/$release/$asset" -o "$stage/archive.tar.gz"
    printf '%s  %s\n' "$sha" "$stage/archive.tar.gz" | shasum -a 256 -c -
    mv "$stage/archive.tar.gz" "$archive"
fi
tar -xzf "$archive" -C "$stage"
python="$stage/python/bin/python3"
"$python" -m pip install --disable-pip-version-check --no-compile "pymobiledevice3==$bridge_version"
"$python" -c 'import ssl; from pymobiledevice3.remote import userspace_tunnel; ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); ctx.set_ciphers("PSK"); assert ssl.HAS_PSK'
if [[ ! -e "$stage/python/bin/python" ]]; then ln -s python3 "$stage/python/bin/python"; fi
printf '%s\n' "$stamp" > "$stage/python/anyway-runtime"
if [[ -d "$runtime" ]]; then mv "$runtime" "$stage/previous"; fi
if ! mv "$stage/python" "$runtime"; then
    if [[ -d "$stage/previous" ]]; then mv "$stage/previous" "$runtime"; fi
    exit 1
fi
