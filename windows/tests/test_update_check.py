import io
import json
import unittest
from unittest.mock import patch

from winloc.update_check import UpdateResult, check_update, current_version, parse_version


class UpdateCheckTests(unittest.TestCase):
    def test_version_comparison_uses_numeric_parts(self):
        self.assertEqual(parse_version("v0.1.10"), (0, 1, 10))
        self.assertIsNone(parse_version("v0.1.1-beta"))
        self.assertTrue(UpdateResult("0.1.9", "0.1.10", "url").required)
        self.assertFalse(UpdateResult("0.1.10", "0.1.9", "url").required)

    def test_latest_release_requires_update(self):
        with patch("winloc.update_check.urlopen",
                   return_value=io.BytesIO(json.dumps({"tag_name": "v0.1.2"}).encode())):
            result = check_update("0.1.1")
        self.assertTrue(result.required)
        self.assertTrue(result.release_url.endswith("/v0.1.2"))

    def test_offline_check_does_not_require_update(self):
        with patch("winloc.update_check.urlopen", side_effect=OSError("offline")):
            result = check_update("0.1.1")
        self.assertFalse(result.required)
        self.assertIn("offline", result.error)

    def test_current_version_comes_from_root_file(self):
        self.assertRegex(current_version(), r"^\d+\.\d+\.\d+$")


if __name__ == "__main__":
    unittest.main()
