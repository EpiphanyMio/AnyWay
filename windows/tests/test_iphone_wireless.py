import base64
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

from anyway import iphone_wireless
from pymobiledevice3.remote import userspace_tunnel


class WirelessIPhoneTests(unittest.IsolatedAsyncioTestCase):
    def test_crypto_check_requires_psk_component(self):
        with patch.object(iphone_wireless, "SSLPSKContext", None), \
             patch.object(iphone_wireless.sys, "version_info", (3, 12)):
            with self.assertRaisesRegex(RuntimeError, "SSL-PSK"):
                iphone_wireless.check_wireless_crypto()

    async def test_authenticated_unicast_service_uses_advertised_port(self):
        from pymobiledevice3.remote.siphash import compute_auth_tag
        b = iphone_wireless.bonjour
        service = b.REMOTEPAIRING_SERVICE_NAME
        instance = "phone." + service
        key = bytes(range(16))
        tag = base64.b64encode(compute_auth_tag(key, "peer")).decode()
        # PTR may arrive alone. Resolve SRV and TXT for that exact instance.
        packets = [
            [{"name": service, "type": b.QTYPE_PTR, "ttl": 30, "ptrdname": instance}],
            [{"name": instance, "type": b.QTYPE_SRV, "ttl": 30, "port": 51102}],
            [{"name": instance, "type": b.QTYPE_TXT, "ttl": 30,
              "txt": {"identifier": "peer", "authTag": tag}}],
        ]
        sock = MagicMock()
        packet = bytes([0, 0, 128]) + bytes(9)
        sock.recv.side_effect = [iphone_wireless.socket.timeout(), packet, packet, packet]
        with patch.object(iphone_wireless.socket, "socket") as socket_factory, \
             patch.object(b, "parse_mdns_message", side_effect=packets), \
             patch.object(iphone_wireless, "iter_remote_pair_records_by_identifier",
                          return_value=[("PHONE", None, {iphone_wireless.PEER_ALT_IRK_KEY: key})]), \
             patch.object(iphone_wireless, "create_core_device_tunnel_service_using_remotepairing",
                          AsyncMock(return_value="provider")) as connect:
            socket_factory.return_value.__enter__.return_value = sock
            self.assertEqual(await iphone_wireless._ip_provider("192.0.2.1", "PHONE"), ("provider", None))
        sock.connect.assert_called_once_with(("192.0.2.1", 5353))
        self.assertEqual(sock.send.call_count, 4)
        connect.assert_awaited_once_with("PHONE", "192.0.2.1", 51102, autopair=False)

    async def test_unknown_advertiser_never_receives_pairing_attempt(self):
        answer = SimpleNamespace(properties={"identifier": "unknown", "authTag": "invalid"})
        with patch.object(iphone_wireless, "_query_wifi_service", return_value=answer), \
             patch.object(iphone_wireless, "iter_remote_pair_records_by_identifier", return_value=[]), \
             patch.object(iphone_wireless, "create_using_tcp", AsyncMock()) as lockdown, \
             patch.object(iphone_wireless, "create_core_device_tunnel_service_using_remotepairing",
                          AsyncMock()) as connect:
            with self.assertRaisesRegex(RuntimeError, "不匹配"):
                await iphone_wireless._ip_provider("192.0.2.1", "SAVED")
        lockdown.assert_not_awaited()
        connect.assert_not_awaited()

    @patch.object(iphone_wireless, "_query_wifi_service", return_value=None)
    async def test_direct_ip_requires_existing_pair_and_matching_identity(self, _query):
        phone = SimpleNamespace(paired=True, udid="OTHER", close=AsyncMock())
        with patch.object(iphone_wireless, "create_using_tcp", AsyncMock(return_value=phone)) as lookup, \
             patch.object(iphone_wireless.CoreDeviceTunnelProxy, "create", AsyncMock()) as proxy:
            with self.assertRaisesRegex(RuntimeError, "未能验证"):
                await iphone_wireless._ip_provider("192.0.2.1", "SAVED")
        lookup.assert_awaited_once_with("192.0.2.1", identifier="SAVED", autopair=False)
        phone.close.assert_awaited_once()
        proxy.assert_not_awaited()

    @patch.object(iphone_wireless, "_query_wifi_service", return_value=None)
    async def test_direct_session_skips_discovery_and_closes_tunnel(self, _query):
        phone = SimpleNamespace(paired=True, udid="PHONE", close=AsyncMock())
        proxy = SimpleNamespace(remote_identifier="PHONE", close=AsyncMock())
        rsd = SimpleNamespace(udid="PHONE")
        async def open_tunnel():
            provider = iphone_wireless.userspace_tunnel._create_no_root_tunnel_provider
            self.assertEqual(await provider("PHONE", False), (proxy, phone))
            return rsd
        tunnel = SimpleNamespace(aopen=open_tunnel, aclose=AsyncMock())
        with patch.object(iphone_wireless, "create_using_tcp", AsyncMock(return_value=phone)), \
             patch.object(iphone_wireless.CoreDeviceTunnelProxy, "create", AsyncMock(return_value=proxy)), \
             patch.object(iphone_wireless.userspace_tunnel, "UserspaceRsdTunnel", return_value=tunnel), \
             patch.object(iphone_wireless, "list_devices", AsyncMock()) as mux:
            async with iphone_wireless.location_tunnel("PHONE", "192.0.2.1") as device:
                self.assertIs(device, rsd)
        mux.assert_not_awaited()
        tunnel.aclose.assert_awaited_once()

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
