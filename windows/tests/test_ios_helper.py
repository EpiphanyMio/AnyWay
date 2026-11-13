import unittest
from unittest.mock import patch

from anyway import ios


class HelperCommandTests(unittest.TestCase):
    def test_frozen_app_uses_console_helper(self):
        with patch.object(ios.sys, "frozen", True, create=True), \
             patch.object(ios.sys, "executable", "/Apps/AnyWay/AnyWay.exe"):
            command = ios._helper_command("--iphone-bridge", "DEVICE")
        self.assertEqual(command[1:], ["--iphone-bridge", "DEVICE"])
        self.assertTrue(command[0].endswith("AnyWayBridge.exe"))


if __name__ == "__main__":
    unittest.main()
