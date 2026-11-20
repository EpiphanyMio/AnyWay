import base64
import sys
import unittest
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import iphone_wireless


class MacWirelessTunnelTests(unittest.IsolatedAsyncioTestCase):
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

    async def test_libressl_uses_macos_native_tunnel(self):
        class FakeNativeTunnel:
            def __init__(self, serial):
                self.serial = serial

            async def __aenter__(self):
                return "RSD"

            async def __aexit__(self, *args):
                return None

        with patch.object(iphone_wireless, "list_devices", AsyncMock(return_value=[])), \
             patch.object(iphone_wireless, "supports_psk_ciphers", return_value=False), \
             patch.object(iphone_wireless, "NativeRemotedTunnel", FakeNativeTunnel), \
             patch.object(iphone_wireless, "get_remote_pairing_tunnel_services",
                          AsyncMock()) as bonjour:
            async with iphone_wireless.location_tunnel("IPHONE") as rsd:
                self.assertEqual(rsd, "RSD")
        bonjour.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
