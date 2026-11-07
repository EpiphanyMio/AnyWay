#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

apk="app/build/outputs/apk/debug/app-debug.apk"
if [ ! -f "$apk" ]; then
    echo "Build the android/ project in Android Studio first (Build > Build APK)." >&2
    exit 1
fi
if ! command -v adb >/dev/null 2>&1; then
    echo "Install Android SDK Platform-Tools and put adb on PATH." >&2
    exit 1
fi
if [ "$#" -ne 1 ]; then
    echo "Usage: bash android/install.sh DEVICE_SERIAL" >&2
    adb devices
    exit 1
fi
adb -s "$1" install -r "$apk"
