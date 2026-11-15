import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from anyway import iphone_wireless
from pymobiledevice3.remote import userspace_tunnel


class WirelessIPhoneTests(unittest.IsolatedAsyncioTestCase):
    def test_crypto_check_requires_psk_component(self):
        with patch.object(iphone_wireless, "SSLPSKContext", None):
            with self.assertRaisesRegex(RuntimeError, "SSL-PSK"):
                iphone_wireless.check_wireless_crypto()

    async def test_discovery_reveals_developer_mode_and_deduplicates_wifi(self):
        usb = SimpleNamespace(serial="IPHONE", is_usb=True)
        lockdown = SimpleNamespace(
            get_developer_mode_status=AsyncMock(return_value=False),
            close=AsyncMock(),
        )
        amfi = SimpleNamespace(reveal_developer_mode_option_in_ui=AsyncMock())
        wifi = SimpleNamespace(remote_identifier="IPHONE", close=AsyncMock())
        with patch.object(iphone_wireless, "list_devices", AsyncMock(return_value=[usb])), \
             patch.object(iphone_wireless, "create_using_usbmux", AsyncMock(return_value=lockdown)), \
             patch.object(iphone_wireless, "AmfiService", return_value=amfi), \
             patch.object(iphone_wireless, "get_remote_pairing_tunnel_services",
                          AsyncMock(return_value=[wifi])):
            inventory = await iphone_wireless.device_inventory()
        self.assertEqual(inventory, {
            "devices": ["IPHONE"], "developerModeRequired": ["IPHONE"],
            "transports": {"IPHONE": "USB"}
        })
        amfi.reveal_developer_mode_option_in_ui.assert_awaited_once()
        wifi.close.assert_awaited_once()
        lockdown.close.assert_awaited_once()

    async def test_wireless_tunnel_uses_paired_bonjour_provider(self):
        provider = SimpleNamespace(close=AsyncMock())

        class FakeTunnel:
            def __init__(self, serial):
                self.serial = serial

            async def aopen(self):
                selected, lockdown = await userspace_tunnel._create_no_root_tunnel_provider(
                    self.serial, True
                )
                assert selected is provider and lockdown is None
                return "RSD"

            async def aclose(self):
                await provider.close()

        with patch.object(iphone_wireless, "list_devices", AsyncMock(return_value=[])), \
             patch.object(iphone_wireless, "check_wireless_crypto"), \
             patch.object(iphone_wireless, "get_remote_pairing_tunnel_services",
                          AsyncMock(return_value=[provider])), \
             patch.object(userspace_tunnel, "UserspaceRsdTunnel", FakeTunnel):
            async with iphone_wireless.location_tunnel("IPHONE") as rsd:
                self.assertEqual(rsd, "RSD")
        provider.close.assert_awaited_once()

    async def test_prepare_enables_wifi_and_remote_pairing(self):
        lockdown = SimpleNamespace(set_enable_wifi_connections=AsyncMock(), close=AsyncMock())
        pairing = SimpleNamespace(connect=AsyncMock(), close=AsyncMock())
        with patch.object(iphone_wireless, "create_using_usbmux", AsyncMock(return_value=lockdown)) as create, \
             patch.object(iphone_wireless.RemotePairingLockdownService, "create",
                          AsyncMock(return_value=pairing)):
            await iphone_wireless.prepare_wireless("IPHONE")
        self.assertEqual(create.await_args.kwargs["connection_type"], "USB")
        lockdown.set_enable_wifi_connections.assert_awaited_once_with(True)
        pairing.connect.assert_awaited_once_with(autopair=True)
        pairing.close.assert_awaited_once()
        lockdown.close.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
