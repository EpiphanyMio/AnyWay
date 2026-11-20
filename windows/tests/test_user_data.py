import tempfile
import unittest
from pathlib import Path

from anyway.user_data import migrate_legacy_data, recent_ip_connections, remember_ip


class MigrationTests(unittest.TestCase):
    def test_recent_ips_migrate_preserve_labels_and_remember_device_identity(self):
        settings = {"direct_iphone": {"address": "192.0.2.1", "udid": "A"}}
        entries = recent_ip_connections(settings)
        entries[0]["name"] = "校园网"
        entries = remember_ip(entries, "192.0.2.2", "A")
        entries = remember_ip(entries, "192.0.2.1", "B")
        entries = remember_ip(entries, "192.0.2.1", "A")
        settings["recent_ip_connections"] = entries
        self.assertEqual(recent_ip_connections(settings), [
            {"address": "192.0.2.1", "udid": "A", "name": "校园网"},
            {"address": "192.0.2.1", "udid": "B", "name": ""},
            {"address": "192.0.2.2", "udid": "A", "name": ""},
        ])

    def test_old_directory_is_renamed_without_losing_files(self):
        with tempfile.TemporaryDirectory() as folder:
            old = Path(folder) / "WindowsLocationSimulator"
            old.mkdir()
            (old / "settings.json").write_text('{"restore":false}')
            (old / "draft.json").write_text('{"name":"route"}')
            target = Path(folder) / "AnyWay"
            migrate_legacy_data(target)
            self.assertFalse(old.exists())
            self.assertTrue((target / "settings.json").exists())
            self.assertTrue((target / "draft.json").exists())

    def test_existing_new_settings_are_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            old = Path(folder) / "WindowsLocationSimulator"
            target = Path(folder) / "AnyWay"
            old.mkdir()
            target.mkdir()
            (old / "settings.json").write_text("old")
            (target / "settings.json").write_text("new")
            (old / "draft.json").write_text("draft")
            migrate_legacy_data(target)
            self.assertEqual((target / "settings.json").read_text(), "new")
            self.assertEqual((target / "draft.json").read_text(), "draft")


if __name__ == "__main__":
    unittest.main()
