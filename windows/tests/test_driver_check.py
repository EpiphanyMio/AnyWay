import subprocess
import sys
import types
import unittest
from unittest.mock import patch

from anyway.driver_check import DriverReport, install_apple_devices, probe


class DriverCheckTests(unittest.TestCase):
    def test_missing_apple_components_offer_official_repair(self):
        report = DriverReport(windows=True, apple_usb_connected=True,
                              mobile_service_installed=False, usb_driver_installed=False)
        self.assertIn("Apple Mobile Device Service", report.missing)
        self.assertIn("Apple Mobile Device USB Driver", report.missing)
        self.assertIn("apps.microsoft.com", report.guide_html())
        self.assertIn("support.apple.com", report.guide_html())

    def test_stopped_service_has_specific_repair_step(self):
        report = DriverReport(windows=True, mobile_service_installed=True,
                              mobile_service_running=False, usb_driver_installed=True)
        self.assertIn("未运行", report.summary())
        self.assertIn("services.msc", report.guide_html())

    def test_no_apple_usb_does_not_claim_iphone_is_connected(self):
        report = DriverReport(windows=True, apple_usb_connected=False,
                              mobile_service_installed=True, mobile_service_running=True,
                              usb_driver_installed=True)
        self.assertFalse(report.apple_usb_connected)
        self.assertEqual(report.missing, ())

    def test_probe_uses_service_state_and_registered_inf(self):
        def result(args):
            if args[0] == "sc.exe":
                return subprocess.CompletedProcess(args, 0, "STATE : 4 RUNNING", "")
            if "/enum-drivers" in args:
                return subprocess.CompletedProcess(args, 0, "Original Name: usbaapl64.inf", "")
            return subprocess.CompletedProcess(args, 0, "USB\\VID_05AC&PID_12A8", "")

        with (patch("anyway.driver_check.sys.platform", "win32"),
              patch.dict(sys.modules, {"winreg": types.SimpleNamespace()}),
              patch("anyway.driver_check._registry_key_exists", side_effect=[True, False, False, False]),
              patch("anyway.driver_check._run", side_effect=result)):
            report = probe()
        self.assertTrue(report.apple_usb_connected)
        self.assertTrue(report.mobile_service_running)
        self.assertTrue(report.usb_driver_installed)

    def test_repair_installs_only_apple_devices_store_package(self):
        with (patch("anyway.driver_check.sys.platform", "win32"),
              patch("anyway.driver_check.shutil.which", return_value="winget.exe"),
              patch("anyway.driver_check.subprocess.run",
                    return_value=subprocess.CompletedProcess([], 0, "", "")) as run):
            self.assertIn("安装完成", install_apple_devices())
        command = run.call_args.args[0]
        self.assertIn("9NP83LWLPZ9K", command)
        self.assertIn("msstore", command)


if __name__ == "__main__":
    unittest.main()
