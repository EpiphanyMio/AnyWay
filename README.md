# AnyWay

AnyWay 是适用于 Mac 和 Windows 的桌面定位模拟器。两个平台共用 `schemaVersion: 1` 的 JSON 配置格式，支持单点定位、路线模拟、约 400 米跑道模板，以及拖动已绘制的路径点调整路线。

Mac 端支持 iOS 模拟器、实体 iPhone 和 Android 实体设备。Windows 端支持实体 iPhone、Android 实体设备，以及 HarmonyOS 7+ 设备。

## 项目结构

- [`mac/`](mac/)：SwiftUI/MapKit 应用、Mac 端 Android 配套工程及 `.pkg` 构建脚本。
- [`windows/`](windows/)：PySide6/Leaflet 应用、Windows 端 Android 配套工程及 `.exe` 安装包脚本。
- [`VERSION`](VERSION)：两个平台共用的软件版本号；当前为 **0.1.0**。
- [`scripts/check_versions.py`](scripts/check_versions.py)：检查平台构建配置是否使用统一版本号。

设备连接和运行步骤分别见 [Mac 说明](mac/README.md) 与 [Windows 说明](windows/README.md)。

## 构建与验证

在 `mac/` 目录执行 `bash scripts/build-app.sh` 构建 Mac 应用；在 Apple Silicon Mac 上执行 `bash scripts/build-pkg.sh` 构建安装包。

在 `windows/` 目录执行 `powershell -ExecutionPolicy Bypass -File scripts\build.ps1` 构建 Windows 应用。仓库 CI 会分别运行 Mac 和 Windows 的测试与应用构建，并检查统一版本号。

新增两端共有的功能时，请同步更新 `mac/` 和 `windows/` 的实现与文档。
