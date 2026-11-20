"""Discover and prepare paired iPhones for a no-root Wi-Fi developer tunnel."""

import asyncio
from ipaddress import IPv4Address
import socket
import ssl
import time
from contextlib import asynccontextmanager
from unittest.mock import patch

from pymobiledevice3 import bonjour
from pymobiledevice3.exceptions import ConnectionTerminatedError, InvalidServiceError, RemotePairingCompletedError
from pymobiledevice3.lockdown import create_using_tcp, create_using_usbmux
from pymobiledevice3.pair_records import iter_remote_paired_identifiers, iter_remote_pair_records_by_identifier
from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
from pymobiledevice3.remote.tunnel_service import (
    CoreDeviceTunnelProxy,
    PEER_ALT_IRK_KEY,
    _match_remote_pair_record,
    create_core_device_tunnel_service_using_remotepairing,
    RemotePairingLockdownService,
    get_remote_pairing_tunnel_services,
)
from pymobiledevice3.services.amfi import AmfiService
from pymobiledevice3.usbmux import list_devices


async def device_inventory():
    """Discover devices and reveal Developer Mode on trusted USB phones."""
    mux_devices = await list_devices()
    found = {device.serial for device in mux_devices}
    transports = {device.serial: ("USB" if device.is_usb else "Wi-Fi")
                  for device in mux_devices}
    for device in mux_devices:
        if device.is_usb:
            transports[device.serial] = "USB"
    developer_mode_required = []
    for device in mux_devices:
        if not device.is_usb:
            continue
        try:
            lockdown = await create_using_usbmux(
                serial=device.serial, connection_type="USB", autopair=False
            )
            try:
                if not await lockdown.get_developer_mode_status():
                    developer_mode_required.append(device.serial)
                    await AmfiService(lockdown).reveal_developer_mode_option_in_ui()
            finally:
                await lockdown.close()
        except Exception:
            # An untrusted or locked device must still remain visible in the list.
            continue
    try:
        services = await get_remote_pairing_tunnel_services(bonjour_timeout=2)
    except Exception:
        # Bonjour can be blocked while an attached USB device still works.
        if not found:
            raise
        services = []
    try:
        for service in services:
            found.add(service.remote_identifier)
            transports.setdefault(service.remote_identifier, "Wi-Fi")
    finally:
        for service in services:
            await service.close()
    return {"devices": sorted(found), "transports": transports,
            "developerModeRequired": developer_mode_required}


async def connected_devices():
    return (await device_inventory())["devices"]


def supports_psk_ciphers():
    """The Wi-Fi TCP tunnel requires PSK suites absent from Xcode's LibreSSL."""
    try:
        ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).set_ciphers("PSK")
    except ssl.SSLError:
        return False
    return True


async def prepare_wireless(udid):
    """One-time setup while the trusted phone is connected over USB."""
    lockdown = await create_using_usbmux(serial=udid, connection_type="USB")
    try:
        await lockdown.set_enable_wifi_connections(True)
        pairing = await RemotePairingLockdownService.create(lockdown)
        try:
            try:
                await pairing.connect(autopair=True)
            except RemotePairingCompletedError:
                # Pair setup closes its channel after saving the new record.
                pass
        finally:
            await pairing.close()
    finally:
        await lockdown.close()


def _query_wifi_service(address):
    """Resolve the paired developer service by unicast DNS-SD to this phone only."""
    service = bonjour.REMOTEPAIRING_SERVICE_NAME
    instance = None
    records = {}
    deadline = time.monotonic() + 4
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect((address, bonjour.MDNS_PORT))

        def request_missing():
            if instance is None:
                sock.send(bonjour.build_query(service, bonjour.QTYPE_PTR))
            else:
                for kind in (bonjour.QTYPE_SRV, bonjour.QTYPE_TXT):
                    if (instance, kind) not in records:
                        sock.send(bonjour.build_query(instance, kind))

        request_missing()
        while time.monotonic() < deadline:
            sock.settimeout(min(1.0, max(0.001, deadline - time.monotonic())))
            try:
                packet = sock.recv(9000)
            except socket.timeout:
                request_missing()
                continue
            except (ConnectionRefusedError, ConnectionResetError):
                break
            if len(packet) < 12 or not (packet[2] & 0x80):
                continue
            try:
                answers = bonjour.parse_mdns_message(packet)
            except (ValueError, IndexError):
                continue
            for answer in answers:
                name = answer["name"].lower()
                if answer.get("ttl") and name.endswith("." + service):
                    records[name, answer["type"]] = answer
            if instance is None:
                for answer in answers:
                    if (answer["name"].lower() == service and answer["type"] == bonjour.QTYPE_PTR
                            and answer.get("ttl") and answer["ptrdname"].lower().endswith("." + service)):
                        instance = answer["ptrdname"].lower()
                        request_missing()
                        break
            port = records.get((instance, bonjour.QTYPE_SRV), {}).get("port")
            properties = records.get((instance, bonjour.QTYPE_TXT), {}).get("txt")
            if port and properties:
                return bonjour.ServiceInstance(instance, None, port, properties=properties)
    return None


async def _ip_provider(address, expected_udid):
    answer = await asyncio.to_thread(_query_wifi_service, address)
    if answer is not None:
        keys = {udid: record[PEER_ALT_IRK_KEY] for udid, _, record in iter_remote_pair_records_by_identifier()
                if PEER_ALT_IRK_KEY in record and (not expected_udid or udid == expected_udid)}
        identifier = _match_remote_pair_record(answer, keys)
        if not identifier:
            raise RuntimeError("手机已响应，但无线配对记录不匹配。请通过 USB 选中这台 iPhone 并重新开启无线连接。")
        try:
            provider = await create_core_device_tunnel_service_using_remotepairing(
                identifier, address, answer.port, autopair=False)
        except (ConnectionTerminatedError, OSError, asyncio.IncompleteReadError) as exc:
            raise RuntimeError(f"手机已公布无线配对端口 {answer.port}，但配对握手中断。请保持 iPhone 解锁后重试。") from exc
        return provider, None

    # Some networks also filter unicast UDP/5353. Retain the lockdown route
    # for phones that expose CoreDeviceProxy through that transport.
    identifiers = [expected_udid] if expected_udid else list(iter_remote_paired_identifiers())
    for identifier in identifiers:
        try:
            lockdown = await create_using_tcp(address, identifier=identifier, autopair=False)
        except ConnectionTerminatedError as exc:
            raise RuntimeError("未收到无线开发者服务公告，备用端口 62078 的配对握手也被关闭。请换用私人热点后刷新设备。") from exc
        if not lockdown.paired or lockdown.udid != identifier:
            await lockdown.close()
            continue
        try:
            proxy = await CoreDeviceTunnelProxy.create(lockdown)
        except BaseException as exc:
            await lockdown.close()
            if isinstance(exc, InvalidServiceError):
                raise RuntimeError("iPhone 配对成功，但未提供 IP 直连所需的开发者隧道。请通过私人热点刷新设备，或使用 USB。") from exc
            raise
        return proxy, lockdown
    raise RuntimeError("未能验证此地址的 iPhone。请先用 USB 信任电脑并在 AnyWay 中开启无线连接。")


@asynccontextmanager
async def ip_tunnel(address, expected_udid=None):
    try:
        host = str(IPv4Address(address))
    except ValueError as exc:
        raise ValueError("请输入 iPhone 的 IPv4 地址，例如 192.168.1.20。") from exc

    verified_udid = expected_udid

    async def provider(serial, autopair, remotepairing_fallback=True):
        nonlocal verified_udid
        proxy, lockdown = await _ip_provider(host, expected_udid)
        verified_udid = proxy.remote_identifier
        return proxy, lockdown

    tunnel = userspace_tunnel.UserspaceRsdTunnel(serial=expected_udid, autopair=False)
    try:
        # Like the Bonjour path, each bridge process owns a single userspace tunnel.
        with patch.object(userspace_tunnel, "_create_no_root_tunnel_provider", provider):
            rsd = await asyncio.wait_for(tunnel.aopen(), 12)
    except ConnectionTerminatedError as exc:
        raise RuntimeError("iPhone 的开发者连接已中断。请解锁手机并重试。") from exc
    except (asyncio.TimeoutError, OSError) as exc:
        raise RuntimeError("连接 iPhone 超时或中断。请解锁手机，核对 Wi-Fi 地址并确认两台设备能相互访问。") from exc
    try:
        if not verified_udid or rsd.udid != verified_udid:
            raise RuntimeError("iPhone 的身份与已保存的设备不一致。")
        yield rsd
    finally:
        await tunnel.aclose()


@asynccontextmanager
async def location_tunnel(udid, address=None):
    """Use usbmux when available; otherwise connect directly to paired Wi-Fi."""
    if address is not None:
        async with ip_tunnel(address, udid) as rsd:
            yield rsd
        return

    if any(device.serial == udid for device in await list_devices()):
        async with userspace_tunnel.UserspaceRsdTunnel(serial=udid) as rsd:
            yield rsd
        return

    if not supports_psk_ciphers():
        # macOS already maintains a trusted network tunnel for Xcode. Reuse it
        # when the bundled Xcode Python cannot negotiate pymobiledevice3's PSK
        # TCP tunnel; RSD services themselves do not negotiate TLS.
        async with NativeRemotedTunnel(serial=udid) as rsd:
            yield rsd
        return

    services = await get_remote_pairing_tunnel_services(udid=udid, bonjour_timeout=5)
    if not services:
        raise RuntimeError("未发现已配对的无线 iPhone。请先用 USB 开启无线连接，并确认电脑与手机在同一网络。")
    provider = services[0]
    for unused in services[1:]:
        await unused.close()

    async def wifi_provider(serial, autopair, remotepairing_fallback=True):
        return provider, None

    tunnel = userspace_tunnel.UserspaceRsdTunnel(serial=udid)
    # This pinned pymobiledevice3 release only accepts a usbmux serial in its
    # public constructor. Supply its already-paired Bonjour provider at open.
    try:
        with patch.object(userspace_tunnel, "_create_no_root_tunnel_provider", wifi_provider):
            rsd = await tunnel.aopen()
    except BaseException:
        await provider.close()
        raise
    try:
        yield rsd
    finally:
        await tunnel.aclose()
