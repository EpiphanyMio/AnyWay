import io
import json
import unittest
from unittest.mock import patch

from anyway.update_check import UpdateResult, check_update, current_version, parse_version


class UpdateCheckTests(unittest.TestCase):
    def test_version_comparison_uses_numeric_parts(self):
        self.assertEqual(parse_version("v0.1.10"), (0, 1, 10))
        self.assertIsNone(parse_version("v0.1.1-beta"))
        self.assertTrue(UpdateResult("0.1.9", "0.1.10", "url").available)
        self.assertFalse(UpdateResult("0.1.10", "0.1.9", "url").available)

    def test_latest_release_provides_notes(self):
        with patch("anyway.update_check.urlopen",
                   return_value=io.BytesIO(json.dumps({"tag_name": "v0.1.2", "body": "## 改进\n- 更新内容"}).encode())):
            result = check_update("0.1.1")
        self.assertTrue(result.available)
        self.assertTrue(result.release_url.endswith("/v0.1.2"))
        self.assertEqual(result.notes, "## 改进\n- 更新内容")

    def test_ignored_release_stays_available_and_newer_release_prompts(self):
        ignored = UpdateResult("0.2.0", "0.2.9", "url")
        self.assertTrue(ignored.available)
        self.assertFalse(ignored.should_prompt("0.2.9"))
        self.assertFalse(ignored.should_prompt("0.2.10"))
        self.assertTrue(UpdateResult("0.2.0", "0.2.10", "url").should_prompt("0.2.9"))

    def test_offline_check_leaves_no_update(self):
        with patch("anyway.update_check.urlopen", side_effect=OSError("offline")):
            result = check_update("0.1.1")
        self.assertFalse(result.available)
        self.assertIn("offline", result.error)

    def test_current_version_comes_from_root_file(self):
        self.assertRegex(current_version(), r"^\d+\.\d+\.\d+$")


if __name__ == "__main__":
    unittest.main()
