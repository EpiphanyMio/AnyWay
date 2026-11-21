"""iOS 17+ developer location bridge over USB or paired Wi-Fi."""
from __future__ import annotations

import json
import queue
import subprocess
import sys
import threading
from pathlib import Path

from .core import Coordinate


def _helper_command(*args: str) -> list[str]:
    if getattr(sys, "frozen", False):
        return [str(Path(sys.executable).with_name("AnyWayBridge.exe")), *args]
    return [sys.executable, *args]


def connected_devices_with_status() -> tuple[list[str], list[str], dict[str, str]]:
    try:
        command = (_helper_command("--list-devices") if getattr(sys, "frozen", False)
                   else [sys.executable, "-m", "anyway.iphone_bridge", "--list-devices"])
        result = subprocess.run(
            command,
            capture_output=True, text=True, timeout=15, check=True,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        inventory = json.loads(result.stdout)
        devices = inventory["devices"]
        if not isinstance(devices, list) or not all(isinstance(d, str) for d in devices):
            raise ValueError("设备列表格式无效。")
        required = inventory.get("developerModeRequired", [])
        transports = inventory.get("transports", {})
        return (devices, required if isinstance(required, list) else [],
                transports if isinstance(transports, dict) else {})
    except FileNotFoundError as exc:
        raise RuntimeError("未找到 Python。请重新安装程序。") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or "").strip()
        raise RuntimeError(f"无法读取 iPhone：{detail or '请安装 Apple Mobile Device Support、解锁并信任电脑。'}") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("读取 iPhone 超时，请检查 USB 或无线网络连接。") from exc


def connected_devices() -> list[str]:
    return connected_devices_with_status()[0]


def check_ip(address: str, expected_udid: str | None = None) -> str:
    args = ["--check-ip", address]
    if expected_udid:
        args.append(expected_udid)
    command = (_helper_command(*args) if getattr(sys, "frozen", False)
               else [sys.executable, "-m", "anyway.iphone_bridge", *args])
    try:
        result = subprocess.run(command, capture_output=True, timeout=30,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("连接 iPhone 超时。请解锁手机并核对 IP 地址。") from exc
    try:
        response = json.loads(result.stdout)
    except ValueError as exc:
        raise RuntimeError("iPhone 桥接程序未返回有效响应，请检查安装。") from exc
    if result.returncode or not response.get("udid"):
        raise RuntimeError(response.get("error") or "无法验证 iPhone 的定位服务。")
    return response["udid"]


def prepare_wireless(udid: str) -> None:
    command = (_helper_command("--prepare-wireless", udid) if getattr(sys, "frozen", False)
               else [sys.executable, "-m", "anyway.iphone_bridge", "--prepare-wireless", udid])
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=45,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("开启无线连接超时。请检查 iPhone 是否已解锁并信任电脑。") from exc
    if result.returncode:
        try:
            detail = json.loads(result.stdout).get("error", "")
        except (ValueError, TypeError):
            detail = (result.stderr or "").strip()
        raise RuntimeError("无法开启 iPhone 无线连接：" + (detail or "请先通过 USB 连接并信任电脑。"))


class PhoneSession:
    def __init__(self):
        self.direct_addresses: dict[str, str] = {}
        self._lock = threading.RLock()
        self._process: subprocess.Popen | None = None
        self._udid: str | None = None
        self._address: str | None = None

    def _read(self, timeout: float = 30) -> dict:
        process = self._process
        if process is None or process.stdout is None:
            raise RuntimeError("iPhone 定位会话未启动。")
        responses: queue.Queue[str] = queue.Queue(maxsize=1)
        threading.Thread(target=lambda: responses.put(process.stdout.readline()), daemon=True).start()
        try:
            line = responses.get(timeout=timeout)
        except queue.Empty as exc:
            self._disconnect()
            raise RuntimeError("iPhone 定位服务响应超时。") from exc
        if not line:
            self._disconnect()
            raise RuntimeError("iPhone 定位服务意外退出。请检查开发者模式及 USB 或无线网络连接。")
        try:
            return json.loads(line)
        except json.JSONDecodeError as exc:
            self._disconnect()
            raise RuntimeError("iPhone 定位服务返回无效数据。") from exc

    def _connect(self, udid: str):
        address = self.direct_addresses.get(udid)
        if (self._process is not None and self._process.poll() is None
                and self._udid == udid and self._address == address):
            return
        if self._process is not None:
            self._disconnect()
        command = (_helper_command("--iphone-bridge", udid) if getattr(sys, "frozen", False)
                   else [sys.executable, "-u", "-m", "anyway.iphone_bridge", udid])
        if address:
            command.append(address)
        self._process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8", bufsize=1,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        self._udid = udid
        self._address = address
        response = self._read(timeout=60)
        if response.get("ready") is not True:
            self._disconnect()
            raise RuntimeError("无法连接 iPhone 开发者定位服务：" + str(response.get("error", "未知错误")))

    def _send(self, request: dict, timeout: float = 30):
        process = self._process
        if process is None or process.stdin is None:
            raise RuntimeError("iPhone 定位会话已断开。")
        try:
            process.stdin.write(json.dumps(request, allow_nan=False) + "\n")
            process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            self._disconnect()
            raise RuntimeError("iPhone 定位会话已断开。") from exc
        response = self._read(timeout)
        if response.get("ok") is not True:
            raise RuntimeError(str(response.get("error", "iPhone 定位操作失败。")))

    def set(self, udid: str, point: Coordinate):
        with self._lock:
            self._connect(udid)
            self._send({"action": "set", "latitude": point.latitude, "longitude": point.longitude})

    def set_keep_awake(self, udid: str, enabled: bool):
        with self._lock:
            if self._udid == udid and self._process is not None and self._process.poll() is None:
                self._send({"action": "keep-awake" if enabled else "allow-sleep"}, timeout=6)

    def clear(self, udid: str):
        with self._lock:
            self._connect(udid)
            try:
                self._send({"action": "clear"})
            finally:
                self._disconnect()

    def close(self):
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                try:
                    self._send({"action": "clear"})
                except Exception:
                    pass
            self._disconnect()

    def _disconnect(self):
        process = self._process
        self._process = None
        self._udid = None
        self._address = None
        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                process.kill()
                process.wait(timeout=3)
            finally:
                for pipe in (process.stdin, process.stdout):
                    if pipe:
                        pipe.close()
