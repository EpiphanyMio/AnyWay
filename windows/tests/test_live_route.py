import unittest
from dataclasses import replace

from anyway.core import Configuration, Coordinate, DynamicPlan, LiveRoute


class LiveRouteTests(unittest.TestCase):
    def setUp(self):
        self.start = Coordinate(30, 120)
        self.end = Coordinate(30.002, 120)
        self.config = Configuration("路线", self.start, [self.start, self.end], 5, 0, 2)

    def test_route_and_pace_edits_keep_lap_progress(self):
        route = LiveRoute(self.config, 12, 0, 1)
        first = route.advance(10)
        moved = Coordinate(30.004, 120)
        route.update(replace(self.config, route=[self.start, moved], speedMetersPerSecond=10, passes=3))
        self.assertEqual(route.lap, 0)
        self.assertEqual(route.config.passes, 3)
        self.assertTrue(route.preview_changed)
        self.assertAlmostEqual(self.start.distance(route.point), 2 * self.start.distance(first), delta=1)
        rejoined = route.point
        self.assertAlmostEqual(rejoined.distance(route.advance(1)), 10, delta=1)

    def test_devices_use_distinct_starts_recovery_intervals_and_lap_trajectories(self):
        shared = replace(self.config, dynamicSpeed=True, dynamicSpeedPlan=DynamicPlan(
            "custom", "campus", .1, 600, 5))
        first, second = LiveRoute(shared, 12, 0, 2), LiveRoute(shared, 31, 1, 2)
        self.assertGreater(first.point.distance(second.point), 1)
        self.assertNotEqual(first.motion.next_recovery, second.motion.next_recovery)
        lap = first.preview()
        self.assertNotEqual(lap, second.preview())
        self.assertLessEqual(max(abs(p.longitude - self.start.longitude) * 96300 for p in lap), 2.01)
        while not first.lap:
            first.advance(1)
        self.assertNotEqual(first.preview(), lap)
