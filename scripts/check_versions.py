"""Check that both platform build paths use the root product version."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text(encoding="utf-8").strip()
assert re.fullmatch(r"\d+\.\d+\.\d+", version), version
notes = json.loads((root / "RELEASE_NOTES.json").read_text(encoding="utf-8"))
assert notes["version"] == version, "RELEASE_NOTES.json must match VERSION"
assert notes["highlights"] and notes["fixes"], "Release notes need updates and fixes"
assert (root / "windows/RELEASE-NOTES.md").read_text(encoding="utf-8").startswith(
    f"# AnyWay {version}\n"
), "Windows release page notes must match VERSION"
checks = {
    "mac/scripts/build-app.sh": ("cat ../VERSION", "cp ../RELEASE_NOTES.json", "<key>CFBundleShortVersionString</key><string>$version</string>",
                                 "<key>CFBundleVersion</key><string>$version</string>"),
    "mac/scripts/build-pkg.sh": ("AnyWay-$version-arm64.pkg",),
    "mac/android/app/build.gradle": ("../../VERSION", "versionCode (versionParts[0]", "versionName productVersion"),
    "windows/android-companion/app/build.gradle.kts": ("../../VERSION", "versionCode = versionParts[0]", "versionName = productVersion"),
    "windows/packaging/windows.iss": ("#error AppVersion must be supplied from the root VERSION file",
                                      "AnyWay-{#AppVersion}-Windows-Setup"),
    "windows/AnyWay.spec": ('("../RELEASE_NOTES.json", ".")',),
    ".github/workflows/release.yml": ("$version = (Get-Content VERSION -Raw).Trim()",
                                      '"/DAppVersion=$version" windows/packaging/windows.iss'),
}
for path, markers in checks.items():
    content = (root / path).read_text(encoding="utf-8")
    for marker in markers:
        assert marker in content, f"{path}: missing {marker}"
print(f"AnyWay {version}: platform versions aligned")
