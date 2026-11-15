# AnyWay 0.2.0

本版新增 Mac 和 Windows 的 iPhone 无线定位，并改进首次连接引导。

## 重大更新

- Mac 和 Windows 支持 iPhone 无线定位。首次用 USB 完成配对后，可通过私人 Wi-Fi 或 iPhone 热点连接。
- 首次连接未开启开发者模式的 iPhone 时，应用会引导用户在手机上完成开启。

## 问题修复

- 修复 Mac 无线连接后无法开始定位模拟的问题。
- 修复 Windows 拔掉 USB 后无法在设备列表中找到已配对 iPhone 的问题。

本版本包含 macOS、Windows 和两端 Android 配套 APK，版本号均来自仓库根目录的 `VERSION` 文件。Android 定位功能本次未改动。

无线连接需要电脑与 iPhone 处于可相互通信的网络。校园网若隔离终端或屏蔽 Bonjour，可能无法发现设备；iPhone 热点或私人 Wi-Fi 可作为替代。
