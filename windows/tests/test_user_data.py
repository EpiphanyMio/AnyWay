import tempfile
import unittest
from pathlib import Path

from anyway.user_data import migrate_legacy_data


class MigrationTests(unittest.TestCase):
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
