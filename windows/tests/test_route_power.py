import importlib.util
import os
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

from anyway.core import Configuration, Coordinate

if importlib.util.find_spec("PySide6"):
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from anyway import app
else:
    app = None


@unittest.skipUnless(app, "PySide6 is needed for route runner tests")
class RoutePowerTests(unittest.TestCase):
    def test_route_failure_releases_phone_and_computer_wake_requests(self):
        start = Coordinate(30, 120)
        config = Configuration("路线", start, [start, Coordinate(30.002, 120)], 5, 0, 1)
        device = Mock()
        device.set.side_effect = [None, RuntimeError("连接断开")]
        execution_state = Mock(return_value=app.ES_CONTINUOUS)
        runner = app.RouteRunner(device, ("ios", "PHONE"), config, 1, 0, 1)
        runner.stop_event = Mock()
        runner.stop_event.is_set.return_value = False
        runner.stop_event.wait.return_value = False
        with patch.object(app, "sys", SimpleNamespace(platform="win32")), \
             patch.object(app.ctypes, "windll", SimpleNamespace(
                 kernel32=SimpleNamespace(SetThreadExecutionState=execution_state)), create=True), \
             patch.object(app, "time", SimpleNamespace(monotonic=Mock(side_effect=[0, 15, 15, 15, 15]))):
            runner.run()
        self.assertEqual(device.set_keep_awake.call_args_list,
                         [call("PHONE", True), call("PHONE", True), call("PHONE", False)])
        self.assertEqual(execution_state.call_args_list,
                         [call(app.ES_CONTINUOUS | app.ES_SYSTEM_REQUIRED), call(app.ES_CONTINUOUS)])
