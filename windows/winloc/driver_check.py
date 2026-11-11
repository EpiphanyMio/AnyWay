"""Windows checks for iPhone USB support and official repair guidance."""
from __future__ import annotations

from dataclasses import dataclass
import re
import shutil
import subprocess
import sys

APPLE_HELP_URL = "https://support.apple.com/en-us/108643"
APPLE_DEVICES_URL = "https://apps.microsoft.com/detail/9np83lwlpz9k"
APPLE_DEVICES_ID = "9NP83LWLPZ9K"


@dataclass(frozen=True)
class DriverReport:
    windows: bool
    apple_usb_connected: bool | None = None
    mobile_service_installed: bool | None = None
    mobile_service_running: bool | None = None
    usb_driver_installed: bool | None = None

    @property
    def missing(self) -> tuple[str, ...]:
        if not self.windows:
            return ()
        missing = []
        if self.mobile_service_installed is False:
            missing.append("Apple Mobile Device Service")
        elif self.mobile_service_running is False:
            missing.append("Apple Mobile Device Service 未运行")
        if self.usb_driver_installed is False:
            missing.append("Apple Mobile Device USB Driver")
        return tuple(missing)

    def summary(self) -> str:
        if not self.windows:
            return "iOS 驱动检测仅适用于 Windows。"
        if self.missing:
            return "iOS 驱动诊断：" + "、".join(self.missing) + " 未就绪。"
        if (self.mobile_service_installed is None or self.mobile_service_running is None
                or self.usb_driver_installed is None):
            return "iOS 驱动诊断：部分组件无法确认，请按指南检查。"
        return "iOS 驱动已检测到；若仍找不到 iPhone，请检查 USB、信任状态和开发者模式。"

    def guide_html(self) -> str:
        if not self.windows:
            return self.summary()
        lines = ["<b>iOS 连接诊断</b><br>" + self.summary()]
        if self.mobile_service_running is False:
            lines.append("服务已安装但未运行：打开 Windows“服务”（services.msc），找到 Apple Mobile Device Service，尝试启动或重新启动。")
        if self.missing or self.mobile_service_installed is None or self.usb_driver_installed is None:
            lines.append(f'驱动补全：可点击下方按钮安装 Apple 官方 <a href="{APPLE_DEVICES_URL}">Apple Devices</a>；'
                         '无需安装完整 iTunes。完成后重新连接 iPhone 并再次检测。')
        lines.append(f'连接排查：解锁手机并选择“信任此电脑”；使用可传输数据的 USB 线；'
                     f'参考 <a href="{APPLE_HELP_URL}">Apple 官方识别设备指南</a>。')
        return "<br>".join(lines)


def _run(args: list[str]) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=10,
                              encoding="utf-8", errors="replace",
                              creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except (OSError, subprocess.TimeoutExpired):
        return None


def _registry_key_exists(winreg, path: str) -> bool | None:
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path):
            return True
    except FileNotFoundError:
        return False
    except OSError:
        return None


def probe() -> DriverReport:
    if sys.platform != "win32":
        return DriverReport(windows=False)
    import winreg

    service = _registry_key_exists(winreg, r"SYSTEM\CurrentControlSet\Services\Apple Mobile Device Service")
    running = None
    if service:
        response = _run(["sc.exe", "query", "Apple Mobile Device Service"])
        if response and response.returncode == 0:
            # The state number is stable across localized Windows installations.
            match = re.search(r":\s*([1-7])\s+(?:\S+)", response.stdout)
            if match:
                running = match.group(1) == "4"

    driver_keys = (r"SYSTEM\CurrentControlSet\Services\usbaapl64",
                   r"SYSTEM\CurrentControlSet\Services\usbaapl",
                   r"SYSTEM\CurrentControlSet\Services\AppleMobileDeviceUSBDriver")
    key_results = [_registry_key_exists(winreg, key) for key in driver_keys]
    driver = True if True in key_results else None if None in key_results else False
    if driver is False:
        response = _run(["pnputil.exe", "/enum-drivers"])
        if response and response.returncode == 0:
            driver = bool(re.search(r"usbaapl(?:64)?\.inf", response.stdout, re.IGNORECASE))
        else:
            driver = None

    apple_usb = None
    response = _run(["pnputil.exe", "/enum-devices", "/connected"])
    if response and response.returncode == 0:
        apple_usb = bool(re.search(r"USB\\VID_05AC", response.stdout, re.IGNORECASE))

    return DriverReport(windows=True, apple_usb_connected=apple_usb,
                        mobile_service_installed=service, mobile_service_running=running,
                        usb_driver_installed=driver)


def install_apple_devices() -> str:
    """Install Apple's supported Windows device package, without installing iTunes."""
    if sys.platform != "win32":
        raise RuntimeError("驱动补全仅适用于 Windows。")
    winget = shutil.which("winget")
    if not winget:
        raise RuntimeError("未找到 Windows 程序包管理器。请通过下方 Apple Devices 链接安装。")
    args = [winget, "install", APPLE_DEVICES_ID, "--source", "msstore",
            "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity"]
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=600,
                                encoding="utf-8", errors="replace",
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError("Apple Devices 安装未完成；请从微软商店手动安装。") from exc
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()[-500:]
        raise RuntimeError("Apple Devices 安装失败：" + (detail or f"退出码 {result.returncode}"))
    return "Apple Devices 安装完成。请重新连接 iPhone，然后再次点击“检查 iOS 驱动”。"
