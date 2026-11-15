import json
import subprocess
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

    def test_device_inventory_includes_developer_mode_hint(self):
        inventory = {"devices": ["PHONE"], "developerModeRequired": ["PHONE"],
                     "transports": {"PHONE": "USB"}}
        result = subprocess.CompletedProcess([], 0, stdout=json.dumps(inventory), stderr="")
        with patch.object(ios.subprocess, "run", return_value=result):
            self.assertEqual(ios.connected_devices_with_status(),
                             (["PHONE"], ["PHONE"], {"PHONE": "USB"}))


if __name__ == "__main__":
    unittest.main()
