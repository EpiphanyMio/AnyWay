"""Discover and prepare paired iPhones for a no-root Wi-Fi developer tunnel."""

import ssl
from contextlib import asynccontextmanager
from unittest.mock import patch

from pymobiledevice3.exceptions import RemotePairingCompletedError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote import userspace_tunnel
from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
from pymobiledevice3.remote.tunnel_service import (
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


@asynccontextmanager
async def location_tunnel(udid):
    """Use usbmux when available; otherwise connect directly to paired Wi-Fi."""
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
