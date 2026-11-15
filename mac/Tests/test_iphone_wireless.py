import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import iphone_wireless


class MacWirelessTunnelTests(unittest.IsolatedAsyncioTestCase):
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
