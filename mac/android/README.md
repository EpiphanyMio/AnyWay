# Android 配套 App

此目录是独立的 Android Gradle 工程，供 Mac 端 LocationSimulator 控制实体 Android 的模拟位置。最低系统版本为 Android 8.0（API 26）。

1. 在 Android Studio 中打开此目录，使用 JDK 17 和 Gradle 8.9，执行 **Build > Build APK**。
2. 在手机上启用开发者选项、USB 调试和系统定位，连接 Mac 并允许 USB 调试授权。
3. 从仓库根目录执行 `adb devices`，然后执行 `bash android/install.sh <设备序列号>`。
4. 在手机的开发者选项中，把“定位模拟器”选为“模拟位置信息应用”。打开配套 App 可检查选择状态。
5. 启动 Mac 版 LocationSimulator，刷新并选中 Android 设备。

Mac 端通过 `adb shell am broadcast` 发送坐标；接收器要求发送者具备 Android 系统 `DUMP` 权限。Android App 不需要网络权限。路径停止后位置保留，使用 Mac 端或配套 App 的“清除模拟定位”恢复系统定位。
