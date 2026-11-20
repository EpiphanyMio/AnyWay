import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

if importlib.util.find_spec("PySide6") is not None:
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtWidgets import QApplication, QLabel, QMainWindow, QVBoxLayout, QWidget
    from anyway import app
    from anyway.user_data import recent_ip_connections
else:
    QApplication = None


@unittest.skipUnless(QApplication, "PySide6 is required for device panel tests")
class DevicePanelTests(unittest.TestCase):
    def test_history_reconnect_uses_saved_identity_and_device_rename_survives_refresh(self):
        qt = QApplication.instance() or QApplication([])
        with tempfile.TemporaryDirectory() as tmp, patch.object(app, "SETTINGS", Path(tmp) / "settings.json"), \
             patch.object(app.MainWindow, "_update_action_state"):
            window = app.MainWindow.__new__(app.MainWindow)
            QMainWindow.__init__(window)
            window.settings = {"direct_iphone": {"address": "192.0.2.1", "udid": "A"}}
            window.device_aliases = window.settings.setdefault("device_aliases", {})
            window.recent_ips = recent_ip_connections(window.settings)
            window.groups = []
            window.ios_session = app.PhoneSession()
            panel = QWidget(window)
            window._build_device_panel(QVBoxLayout(panel))
            window.status = QLabel(window)
            window._device_task = lambda work, done, *args: done(work())
            with patch.object(app.QInputDialog, "getText", return_value=("校园网", True)):
                window.rename_ip_button.click()
            window.iphone_ip.setText("192.0.2.2")
            with patch.object(app, "check_ip", side_effect=RuntimeError("连接失败")), \
                 self.assertRaises(RuntimeError):
                window.connect_ios_ip()
            self.assertEqual(window.recent_combo.count(), 1)
            with patch.object(app, "check_ip", return_value="A") as check:
                window.reconnect_button.click()
                check.assert_called_once_with("192.0.2.1", "A")
            with patch.object(app.QInputDialog, "getText", return_value=("我的手机", True)):
                window.rename_device_button.click()
            self.assertEqual(window.device_combo.count(), 1)
            self.assertIn("我的手机", window.device_combo.currentText())
            window._set_devices(([("ios", "A")], [], False, [], {"A": "USB"}, {}))
            self.assertIn("我的手机", window.device_combo.currentText())
            self.assertIn("USB", window.device_combo.currentText())
            self.assertIn("校园网", window.recent_combo.currentText())
            self.assertIn("我的手机", window.recent_combo.currentText())
            prefs = json.loads(app.SETTINGS.read_text(encoding="utf-8"))
            self.assertEqual(recent_ip_connections(prefs)[0]["name"], "校园网")
            self.assertEqual(prefs["device_aliases"]["ios:A"], "我的手机")
            self.assertEqual(window.device_combo.count(), 1)
            window.deleteLater()
            qt.processEvents()
