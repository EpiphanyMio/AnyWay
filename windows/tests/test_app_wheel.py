"""Interaction tests for the sidebar's click-to-adjust numeric fields."""
import importlib.util
import os
import unittest


if importlib.util.find_spec("PySide6") is not None:
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    from PySide6.QtCore import QPoint, QPointF, Qt
    from PySide6.QtGui import QWheelEvent
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QApplication, QLineEdit, QVBoxLayout, QWidget

    from winloc.app import ClickToWheelDoubleSpinBox, ClickToWheelSpinBox
else:
    QApplication = None


@unittest.skipUnless(QApplication is not None, "PySide6 is required for UI interaction tests")
class ClickToWheelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.window = QWidget()
        layout = QVBoxLayout(self.window)
        self.integer = ClickToWheelSpinBox()
        self.integer.setRange(0, 100)
        self.integer.setValue(10)
        self.decimal = ClickToWheelDoubleSpinBox()
        self.decimal.setRange(0, 100)
        self.decimal.setValue(10)
        self.other = QLineEdit()
        for widget in (self.integer, self.decimal, self.other):
            layout.addWidget(widget)
        self.window.show()
        self.window.activateWindow()
        self.app.processEvents()

    def tearDown(self):
        self.window.close()

    @staticmethod
    def wheel(widget):
        event = QWheelEvent(
            QPointF(5, 5), QPointF(5, 5), QPoint(0, 0), QPoint(0, -120),
            Qt.MouseButton.NoButton, Qt.KeyboardModifier.NoModifier,
            Qt.ScrollPhase.ScrollUpdate, False,
        )
        QApplication.sendEvent(widget, event)
        return event

    def test_hover_and_keyboard_focus_do_not_change_values(self):
        for widget in (self.integer, self.decimal):
            widget.setFocus()
            self.app.processEvents()
            event = self.wheel(widget)
            self.assertEqual(widget.value(), 10)
            self.assertFalse(event.isAccepted())

    def test_click_enables_wheel_only_until_focus_leaves(self):
        for widget in (self.integer, self.decimal):
            QTest.mouseClick(widget.findChild(QLineEdit), Qt.MouseButton.LeftButton)
            self.app.processEvents()
            event = self.wheel(widget)
            self.assertLess(widget.value(), 10)
            self.assertTrue(event.isAccepted())

            self.other.setFocus()
            self.app.processEvents()
            value = widget.value()
            event = self.wheel(widget)
            self.assertEqual(widget.value(), value)
            self.assertFalse(event.isAccepted())


if __name__ == "__main__":
    unittest.main()
