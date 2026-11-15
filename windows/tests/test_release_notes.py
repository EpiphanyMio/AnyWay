import unittest

from anyway.release_notes import load
from anyway.update_check import current_version


class ReleaseNotesTests(unittest.TestCase):
    def test_notes_match_product_version(self):
        notes = load(current_version())
        self.assertIsNotNone(notes)
        self.assertTrue(notes.highlights)
        self.assertTrue(notes.fixes)
        self.assertIsNone(load("0.0.0"))


if __name__ == "__main__":
    unittest.main()
