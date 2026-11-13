import io
import json
import unittest
from unittest.mock import patch

from anyway.place_search import _is_campus, search_places


class PlaceSearchTests(unittest.TestCase):
    def test_school_results_keep_campuses_immediately_after_main_school(self):
        records = [
            {"name": "北京大学", "lat": "39.99", "lon": "116.31",
             "category": "amenity", "type": "university"},
            {"name": "清华大学", "lat": "40.00", "lon": "116.32",
             "category": "amenity", "type": "university"},
            {"name": "北京大学（昌平校区）", "lat": "40.20", "lon": "116.20",
             "category": "amenity", "type": "university"},
            {"name": "北京大学大兴分校", "lat": "39.70", "lon": "116.25",
             "category": "amenity", "type": "university"},
        ]
        with patch("anyway.place_search._overpass_campuses", return_value=[]), patch(
                "anyway.place_search.urlopen",
                return_value=io.BytesIO(json.dumps(records).encode())) as open_url:
            results = search_places("北京大学")
        self.assertEqual([place["name"] for place in results[:3]],
                         ["北京大学", "北京大学（昌平校区）", "北京大学大兴分校"])
        self.assertEqual(results[3]["name"], "清华大学")
        open_url.assert_called_once()

    def test_known_campus_is_included_for_parent_school(self):
        records = [{"name": "北京邮电大学", "lat": "39.95", "lon": "116.35",
                    "category": "amenity", "type": "university"}]
        with patch("anyway.place_search._overpass_campuses", return_value=[]), patch(
                "anyway.place_search.urlopen",
                return_value=io.BytesIO(json.dumps(records).encode())):
            results = search_places("北邮")
        self.assertEqual([place["name"] for place in results[:2]],
                         ["北京邮电大学", "北京邮电大学（沙河校区）"])

    def test_other_school_is_not_treated_as_a_campus(self):
        self.assertFalse(_is_campus("清华大学沙河校区", "北京大学"))
        self.assertTrue(_is_campus("北京大学（昌平校区）", "北京大学"))

    def test_campus_query_uses_secondary_osm_results(self):
        records = [{"name": "浙江大学（西溪校区）", "lat": "30.27", "lon": "120.14",
                    "category": "amenity", "type": "university"}]
        from anyway.core import Coordinate
        other_campuses = [{"name": "浙江大学（紫金港校区）", "subtitle": "OpenStreetMap",
                           "point": Coordinate(30.31, 120.09), "school": True}]
        with patch("anyway.place_search._overpass_campuses", return_value=other_campuses), patch(
                "anyway.place_search.urlopen",
                return_value=io.BytesIO(json.dumps(records).encode())):
            results = search_places("浙江大学")
        self.assertEqual([place["name"] for place in results],
                         ["浙江大学（西溪校区）", "浙江大学（紫金港校区）"])


if __name__ == "__main__":
    unittest.main()
