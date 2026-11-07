"""One-time migration of the Mac repository into the AnyWay monorepo."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WINDOWS_COMMIT = "4e83cb22afa4eeb5ec013883fc6c2fd1776c3046"
VERSION = "0.1.0"


def run(*args: str, cwd: Path = ROOT) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def change(path: str, old: str, new: str) -> None:
    file = ROOT / path
    text = file.read_text(encoding="utf-8")
    if old not in text:
        raise RuntimeError(f"Expected text missing in {path}: {old[:80]}")
    file.write_text(text.replace(old, new), encoding="utf-8")


def main() -> None:
    if (ROOT / "mac").exists() or (ROOT / "windows").exists():
        raise RuntimeError("Platform directories already exist; migration is one-time only.")
    (ROOT / "mac").mkdir()
    (ROOT / "windows").mkdir()
    for path in ("Package.swift", "Sources", "Tests", "android", "README.md", ".gitignore"):
        run("git", "mv", path, "mac/" + path)
    (ROOT / "mac/scripts").mkdir()
    for path in ("build-app.sh", "build-pkg.sh", "install-iphone-support.sh", "iphone_location_bridge.py"):
        run("git", "mv", "scripts/" + path, "mac/scripts/" + path)

    with tempfile.TemporaryDirectory() as temporary:
        checkout = Path(temporary) / "winls"
        run("git", "clone", "--quiet", "https://github.com/EpiphanyMio/WinLS.git", str(checkout))
        run("git", "checkout", "--quiet", WINDOWS_COMMIT, cwd=checkout)
        archive = subprocess.Popen(["git", "archive", WINDOWS_COMMIT], cwd=checkout, stdout=subprocess.PIPE)
        try:
            subprocess.run(["tar", "-x", "-C", str(ROOT / "windows")], stdin=archive.stdout, check=True)
        finally:
            if archive.stdout:
                archive.stdout.close()
        if archive.wait() != 0:
            raise RuntimeError("Failed to export Windows source tree")
    (ROOT / "windows/.github/workflows/beta-release.yml").unlink()
    shutil.rmtree(ROOT / "windows/.github")

    (ROOT / "VERSION").write_text(VERSION + "\n", encoding="utf-8")
    change("mac/Package.swift", 'let package = Package(\n    name: "LocationSimulator",',
           'let package = Package(\n    name: "AnyWay",')
    change("mac/Sources/LocationSimulator/LocationSimulatorApp.swift",
           'WindowGroup("定位模拟器")', 'WindowGroup("AnyWay")')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           'final class RoutePointAnnotation: MKPointAnnotation {}',
           'final class RoutePointAnnotation: MKPointAnnotation { var index = 0 }')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '    let singlePoint: Coordinate?\n    let onMapClick: (Coordinate) -> Void',
           '    let singlePoint: Coordinate?\n    let editable: Bool\n    let onPointMoved: (Int, Coordinate) -> Void\n    let onMapClick: (Coordinate) -> Void')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '            let markerStep = points.count > 30 ? max(1, points.count / 12) : 1\n', '')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '                if points.count > 30 && index > 1 && index % markerStep != 0 { continue }\n', '')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '                let annotation = RoutePointAnnotation()\n                annotation.coordinate',
           '                let annotation = RoutePointAnnotation()\n                annotation.index = index\n                annotation.coordinate')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '        if coordinator.renderedSearchCoordinate != searchCoordinate',
           '        if coordinator.renderedEditable != editable {\n'
           '            coordinator.renderedEditable = editable\n'
           '            for annotation in map.annotations where annotation is RoutePointAnnotation {\n'
           '                map.view(for: annotation)?.isDraggable = editable\n'
           '            }\n'
           '        }\n'
           '        if coordinator.renderedSearchCoordinate != searchCoordinate')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '        var renderedPoints: [Coordinate] = []',
           '        var renderedPoints: [Coordinate] = []\n        var renderedEditable: Bool?')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '            view.canShowCallout = isSearch || isSinglePoint\n            return view',
           '            view.canShowCallout = isSearch || isSinglePoint\n'
           '            view.isDraggable = annotation is RoutePointAnnotation && parent.editable\n'
           '            return view')
    change("mac/Sources/LocationSimulator/RouteMapView.swift",
           '        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {',
           '        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,\n'
           '                     didChange newState: MKAnnotationView.DragState,\n'
           '                     fromOldState oldState: MKAnnotationView.DragState) {\n'
           '            guard newState == .ending, parent.editable,\n'
           '                  let annotation = view.annotation as? RoutePointAnnotation,\n'
           '                  annotation.index < parent.points.count,\n'
           '                  let point = try? Coordinate(latitude: annotation.coordinate.latitude,\n'
           '                                              longitude: annotation.coordinate.longitude) else { return }\n'
           '            parent.onPointMoved(annotation.index, point)\n'
           '            view.dragState = .none\n'
           '        }\n\n'
           '        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {')
    change("mac/Sources/LocationSimulator/ContentView.swift",
           '                         singlePoint: try? RouteParser.coordinate(latitude: latitude, longitude: longitude)) { point in',
           '                         singlePoint: try? RouteParser.coordinate(latitude: latitude, longitude: longitude),\n'
           '                         editable: !controller.isRunning && !textPending,\n'
           '                         onPointMoved: { index, point in\n'
           '                guard !controller.isRunning, !textPending, points.indices.contains(index) else { return }\n'
           '                points[index] = point\n'
           '                syncRouteText()\n'
           '                controller.status = "已移动第 \\(index + 1) 个路径点。"\n'
           '            }) { point in')
    change("mac/scripts/build-app.sh", '.build/LocationSimulator.app', '.build/AnyWay.app')
    change("mac/scripts/build-app.sh", "cat > \"$app_dir/Contents/Info.plist\" <<'PLIST'",
           'version="$(cat ../VERSION)"\ncat > "$app_dir/Contents/Info.plist" <<PLIST')
    change("mac/scripts/build-app.sh", "<string>LocationSimulator</string>\n    <key>CFBundleDisplayName</key><string>定位模拟器</string>",
           "<string>AnyWay</string>\n    <key>CFBundleDisplayName</key><string>AnyWay</string>")
    change("mac/scripts/build-app.sh", "<key>CFBundleShortVersionString</key><string>1.1.0</string>",
           "<key>CFBundleShortVersionString</key><string>$version</string>")
    change("mac/scripts/build-pkg.sh", '.build/LocationSimulator.app', '.build/AnyWay.app')
    change("mac/scripts/build-pkg.sh", 'pkg_name="LocationSimulator-$version-arm64.pkg"',
           'pkg_name="AnyWay-$version-arm64.pkg"')
    change("mac/android/app/build.gradle", "versionName '1.0'",
           "versionName new File(rootDir, '../../VERSION').text.trim()")
    change("mac/README.md", "LocationSimulator-1.1.0-arm64.pkg", "AnyWay-0.1.0-arm64.pkg")
    change("mac/README.md", ".build/LocationSimulator.app", ".build/AnyWay.app")

    change("windows/packaging/windows.iss", "AppName=WinLS", "AppName=AnyWay")
    change("windows/packaging/windows.iss", "DefaultGroupName=WinLS", "DefaultGroupName=AnyWay")
    change("windows/packaging/windows.iss", "OutputBaseFilename=WinLS-{#AppVersion}-Windows-Setup",
           "OutputBaseFilename=AnyWay-{#AppVersion}-Windows-Setup")
    change("windows/packaging/windows.iss", 'Name: "{group}\\WinLS"', 'Name: "{group}\\AnyWay"')
    change("windows/packaging/windows.iss", 'Name: "{autodesktop}\\WinLS"', 'Name: "{autodesktop}\\AnyWay"')
    change("windows/packaging/windows.iss", "Description: \"Launch WinLS\"", "Description: \"Launch AnyWay\"")
    change("windows/winloc/app.py", 'self.setWindowTitle("定位模拟器 · Windows")',
           'self.setWindowTitle("AnyWay · Windows")')
    change("windows/winloc/app.py", 'toolbar.addWidget(QLabel("定位模拟器 · Windows"))',
           'toolbar.addWidget(QLabel("AnyWay · Windows"))')
    change("windows/launcher.py", 'print("WinLS imports OK")', 'print("AnyWay imports OK")')
    change("windows/android-companion/app/build.gradle.kts", 'versionName = "0.1.0"',
           'versionName = rootProject.file("../../VERSION").readText().trim()')
    change("windows/README.md", "# 定位模拟器 · Windows", "# AnyWay · Windows")
    (ROOT / "README.md").write_text(README, encoding="utf-8")
    (ROOT / "AGENTS.md").write_text(AGENTS, encoding="utf-8")
    (ROOT / ".gitignore").write_text(".DS_Store\n__pycache__/\n*.py[cod]\n", encoding="utf-8")
    (ROOT / "scripts/check_versions.py").write_text(VERSION_CHECK, encoding="utf-8")
    (ROOT / ".github/workflows/ci.yml").parent.mkdir(parents=True, exist_ok=True)
    (ROOT / ".github/workflows/ci.yml").write_text(CI, encoding="utf-8")


README = """# AnyWay

AnyWay 是 Mac 和 Windows 的桌面定位模拟器，共用 JSON 配置格式（`schemaVersion: 1`）。两端支持单点、路线与约 400 米跑道模板；已绘制路径点可拖动调整。Mac 端支持 iOS 模拟器与实体 iPhone，Windows 端支持实体 iPhone；两端均可连接 Android 实体设备，Windows 端还支持 HarmonyOS 7+ 的 hdc/testhelper。

## 仓库结构

- `mac/`：SwiftUI/MapKit 应用、Mac Android 配套工程和 `.pkg` 构建脚本。
- `windows/`：PySide6/Leaflet 应用、Windows Android 配套工程和 `.exe` 安装包脚本。
- `VERSION`：两个桌面应用和配套 App 的统一版本号。修改版本时只编辑此文件。
- `scripts/check_versions.py` 和 `.github/workflows/ci.yml`：跨平台版本与构建检查。

Mac 运行和设备连接步骤见 [mac/README.md](mac/README.md)；Windows 步骤见 [windows/README.md](windows/README.md)。

## 构建

- Mac：在 `mac/` 执行 `bash scripts/build-app.sh`；Apple Silicon 安装包执行 `bash scripts/build-pkg.sh`。
- Windows：在 `windows/` 执行 `powershell -ExecutionPolicy Bypass -File scripts\\build.ps1`，然后以根目录 `VERSION` 的值编译 `packaging/windows.iss`。

每次修改共用功能、配置格式或版本号时，检查两个平台的实现与说明，并运行对应测试。仓库 CI 分别执行 Swift 和 Python 测试、构建两端应用。
"""

AGENTS = """# AnyWay development rules

- This is one product with two platform implementations: `mac/` and `windows/`. For a user-facing feature or behavior change, inspect both and implement the equivalent behavior on both unless the feature is platform-specific.
- The single product version is the root `VERSION` file. Mac app/pkg, Windows installer, and both Android companion builds must derive their version from it. Never bump only one platform.
- Keep the JSON configuration schema compatible across platforms (`schemaVersion: 1`); update both readers/writers and both sets of tests when the schema changes.
- Preserve platform-specific device bridges inside their platform directories. Shared documentation and version policy stay at the repository root.
- For a release, build/test both platforms, then publish both platform artifacts under the same version tag. Do not describe a release as cross-platform until both artifacts exist.
"""

VERSION_CHECK = '''"""Check that both platform build paths use the root product version."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text(encoding="utf-8").strip()
assert re.fullmatch(r"\\d+\\.\\d+\\.\\d+", version), version
checks = {
    "mac/scripts/build-app.sh": ("cat ../VERSION", "<string>$version</string>"),
    "mac/scripts/build-pkg.sh": ("AnyWay-$version-arm64.pkg",),
    "mac/android/app/build.gradle": ("../../VERSION",),
    "windows/android-companion/app/build.gradle.kts": ("../../VERSION",),
    "windows/packaging/windows.iss": (f'#define AppVersion "{version}"', "AnyWay-{#AppVersion}-Windows-Setup"),
}
for path, markers in checks.items():
    content = (root / path).read_text(encoding="utf-8")
    for marker in markers:
        assert marker in content, f"{path}: missing {marker}"
print(f"AnyWay {version}: platform versions aligned")
'''

CI = """name: AnyWay cross-platform CI
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:

jobs:
  version:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: python scripts/check_versions.py
  mac:
    needs: version
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Test Mac application
        working-directory: mac
        run: swift test
      - name: Build Mac application
        working-directory: mac
        run: bash scripts/build-app.sh
  windows:
    needs: version
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
          architecture: x64
      - name: Test Windows application
        working-directory: windows
        shell: pwsh
        run: python -m unittest discover -s tests -v
      - name: Build Windows application
        working-directory: windows
        shell: pwsh
        run: ./scripts/build.ps1
      - name: Smoke test Windows executable
        shell: pwsh
        run: |
          & ./windows/dist/WindowsLocationSimulator/WindowsLocationSimulator.exe --self-test
          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
"""


if __name__ == "__main__":
    main()

